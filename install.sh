cd ~
mkdir -p ~/msg-server/public
cd ~/msg-server

cat << 'EOF' > package.json
{
  "name": "termux-msg-server",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "socket.io": "^4.7.5"
  }
}
EOF

npm install

cat << 'EOF' > auth.js
const activeUsers = new Map();
const socketToId = new Map();

function isValidId(id) {
    return typeof id === 'string' && /^\d{6}$/.test(id);
}

function registerUser(socketId, requestedId, profileData) {
    if (!isValidId(requestedId)) {
        return { success: false, error: 'ID must be exactly 6 digits.' };
    }
    const existing = activeUsers.get(requestedId);
    if (existing && existing.socketId !== socketId) {
        return { success: false, error: 'This 6-digit ID is currently in use.' };
    }
    const oldId = socketToId.get(socketId);
    if (oldId && oldId !== requestedId) {
        activeUsers.delete(oldId);
    }
    activeUsers.set(requestedId, { socketId, profile: profileData || {} });
    socketToId.set(socketId, requestedId);
    return { success: true, id: requestedId };
}

function removeUserBySocket(socketId) {
    const id = socketToId.get(socketId);
    if (id) {
        activeUsers.delete(id);
        socketToId.delete(socketId);
    }
    return id;
}

function getUserById(id) {
    return activeUsers.get(id) || null;
}

function getIdBySocket(socketId) {
    return socketToId.get(socketId) || null;
}

module.exports = { registerUser, removeUserBySocket, getUserById, getIdBySocket };
EOF

cat << 'EOF' > profile.js
function sanitizePublicProfile(rawProfile = {}) {
    const toggles = rawProfile.toggles || {};
    return {
        username: String(rawProfile.username || 'Anonymous').trim().slice(0, 24),
        avatar: rawProfile.avatar || 'default',
        bannerColor: rawProfile.bannerColor || '#1f2833',
        pronouns: toggles.showPronouns && rawProfile.pronouns
            ? String(rawProfile.pronouns).trim().slice(0, 20)
            : null,
        description: toggles.showDescription && rawProfile.description
            ? String(rawProfile.description).trim().slice(0, 160)
            : null,
        customFields: toggles.showCustomFields && Array.isArray(rawProfile.customFields)
            ? rawProfile.customFields.slice(0, 5)
            : []
    };
}

module.exports = { sanitizePublicProfile };
EOF

cat << 'EOF' > messages.js
const auth = require('./auth');
const { sanitizePublicProfile } = require('./profile');

function attachSocketHandlers(io) {
    io.on('connection', (socket) => {
        socket.on('register_id', ({ id, profile }, callback) => {
            const cleanProfile = sanitizePublicProfile(profile);
            const result = auth.registerUser(socket.id, id, cleanProfile);
            if (typeof callback === 'function') callback(result);
        });

        socket.on('update_profile', (profile) => {
            const currentId = auth.getIdBySocket(socket.id);
            if (currentId) {
                auth.registerUser(socket.id, currentId, sanitizePublicProfile(profile));
            }
        });

        socket.on('send_friend_ping', ({ targetId }, callback) => {
            const senderId = auth.getIdBySocket(socket.id);
            const sender = auth.getUserById(senderId);
            const target = auth.getUserById(targetId);

            if (!sender) return callback?.({ success: false, error: 'Register a 6-digit ID first.' });
            if (!target || targetId === senderId) return callback?.({ success: false, error: 'User is offline or invalid ID.' });

            io.to(target.socketId).emit('incoming_friend_ping', {
                fromId: senderId,
                profile: sender.profile
            });
            callback?.({ success: true });
        });

        socket.on('accept_friend_ping', ({ requesterId }) => {
            const accepterId = auth.getIdBySocket(socket.id);
            const accepter = auth.getUserById(accepterId);
            const requester = auth.getUserById(requesterId);
            if (!accepter || !requester) return;

            io.to(requester.socketId).emit('handshake_complete', {
                friendId: accepterId,
                profile: accepter.profile
            });
            socket.emit('handshake_complete', {
                friendId: requesterId,
                profile: requester.profile
            });
        });

        socket.on('check_presence', ({ targetId }, callback) => {
            const target = auth.getUserById(targetId);
            callback?.({ online: Boolean(target) });
        });

        socket.on('send_message', ({ targetId, text, timestamp }, callback) => {
            const senderId = auth.getIdBySocket(socket.id);
            const target = auth.getUserById(targetId);
            if (!senderId || !target) return callback?.({ delivered: false, error: 'Recipient is offline.' });

            io.to(target.socketId).emit('receive_message', {
                fromId: senderId,
                text: String(text || '').slice(0, 2000),
                timestamp: timestamp || Date.now()
            });
            callback?.({ delivered: true });
        });

        socket.on('disconnect', () => {
            auth.removeUserBySocket(socket.id);
        });
    });
}

module.exports = { attachSocketHandlers };
EOF

cat << 'EOF' > server.js
const express = require('express');
const http = require('http');
const path = require('path');
const { Server } = require('socket.io');
const { attachSocketHandlers } = require('./messages');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: { origin: '*' },
    maxHttpBufferSize: 1e6
});

app.set('trust proxy', 1);
app.use(express.json({ limit: '1mb' }));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/health', (req, res) => {
    res.status(200).json({ status: 'online', timestamp: Date.now() });
});

attachSocketHandlers(io);

const PORT = process.env.PORT || 3000;
server.listen(PORT, '0.0.0.0', () => {
    console.log(`[Server] Running on http://localhost:${PORT}`);
});
EOF

# Create the startup script (start.sh) inside the folder
cat << 'EOF' > start.sh
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
cd ~/msg-server
node server.js &
cloudflared tunnel --url http://localhost:3000
EOF
chmod +x start.sh

echo "install.sh finished successfully! To run your server anytime, just type: cd ~/msg-server && ./start.sh"
