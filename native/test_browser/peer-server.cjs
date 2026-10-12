const {PeerServer} = require('peer');
PeerServer({port: 9000, path: '/peerjs', allow_discovery: false});
