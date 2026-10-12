import {initial,play} from './engine.js';
import {VERSION,acceptMove,restore} from './protocol.js';

let loading;
function loadPeer(){
  if(globalThis.Peer)return Promise.resolve(globalThis.Peer);
  if(loading)return loading;
  loading=new Promise((resolve,reject)=>{
    const script=document.createElement('script');
    script.src='./vendor/peerjs.min.js';
    script.onload=()=>globalThis.Peer?resolve(globalThis.Peer):reject(new Error('PeerJSを読み込めませんでした。'));
    script.onerror=()=>{script.remove();loading=null;reject(new Error('接続ライブラリを読み込めませんでした。再試行してください。'));};
    document.head.append(script);
  });
  return loading;
}
const uid=()=>crypto.randomUUID();
export class Room {
  constructor({onState,onStatus}){
    this.onState=onState;this.onStatus=onStatus;this.state=initial();this.match=uid();this.rev=-1;
    this.peer=null;this.conn=null;this.host=false;this.role=0;this.ready=false;this.pending=false;
    this.localVote=false;this.remoteVote=false;this.guestToken=null;this.closed=false;this.attempt=0;
    this.identity=uid();this.invite='';this.target='';this.timeout=null;this.heartbeat=null;this.lastSeen=0;
    this.spectator=false;this.watchers=new Map();this.playing=false;
  }
  status(text){this.onStatus(text,this);}
  get canMove(){return this.ready&&!this.pending&&this.state.turn===this.role&&!this.state.result;}
  async start(target='',spectator=false){
    this.target=target;this.host=!target;this.spectator=!!target&&spectator;this.role=this.host?1:this.spectator?0:2;this.status('接続を準備しています…');
    const attempt=++this.attempt;
    try{
      const Peer=await loadPeer();if(this.closed||attempt!==this.attempt)return;
      // Production uses the free PeerJS Cloud; tests inject a local broker.
      const options={secure:true,...(globalThis.__PEER_OPTIONS__??{})};
      const peer=this.peer=new Peer(undefined,options);
      this.armTimeout('接続できませんでした。「再接続」を試すか、別の回線でお試しください。');
      peer.on('open',id=>{
        if(this.closed||this.peer!==peer)return;
        clearTimeout(this.timeout);
        if(this.host){const url=new URL(location.href);url.hash=`room=${id}`;this.invite=url.href;this.status(this.ready?'友達と接続しました。':this.guestToken?'友達の再接続を待っています。':'招待リンクを友達に送ってください。');}
        else this.connect();
      });
      peer.on('connection',conn=>{
        if(!this.host||this.closed){conn.on('open',()=>conn.close());return;}
        const meta=conn.metadata;
        if(meta?.version===VERSION&&meta.watch===true){this.attachWatcher(conn);return;}
        if(meta?.version!==VERSION || typeof meta.token!=='string' || meta.token.length>100){
          const reject=()=>{if(conn.open)conn.send({type:'rejected',version:VERSION});};
          let timeout;
          conn.on('open',()=>{reject();timeout=setTimeout(()=>conn.close(),20000);});
          conn.on('data',message=>{if(message?.version!==VERSION)return;if(message.type==='sync')reject();if(message.type==='rejected-ack')conn.close();});
          conn.on('close',()=>clearTimeout(timeout));conn.on('error',()=>{clearTimeout(timeout);conn.close();});return;
        }
        if((this.guestToken&&this.guestToken!==meta.token)||this.conn){this.attachWatcher(conn);return;}
        this.attach(conn);
      });
      peer.on('disconnected',()=>{
        if(this.closed||this.peer!==peer)return;
        if(!this.ready)this.status('接続サービスとの通信が切れました。再接続してください。');
        try{peer.reconnect();}catch{}
      });
      peer.on('error',error=>{
        if(this.closed||this.peer!==peer)return;
        clearTimeout(this.timeout);
        if(this.ready)return;
        this.pending=false;
        this.status(error.type==='peer-unavailable'?'部屋が見つかりません。作成者が画面を開いているか確認してください。':'接続できませんでした。再接続するか、別の回線でお試しください。');
      });
    }catch(error){if(!this.closed&&attempt===this.attempt)this.status(error.message);}
  }
  armTimeout(message){clearTimeout(this.timeout);this.timeout=setTimeout(()=>{if(!this.ready&&!this.closed){this.conn?.close();this.conn=null;this.pending=false;this.status(message);}},20000);}
  connect(){
    if(this.closed||!this.peer||this.conn)return;
    this.status('友達の部屋に接続しています…');
    this.armTimeout('つながりませんでした。作成者の画面と回線を確認して再接続してください。');
    this.attach(this.peer.connect(this.target,{reliable:true,serialization:'json',metadata:{version:VERSION,token:this.identity,watch:this.spectator}}));
  }
  snapshot(){return {type:'state',version:VERSION,match:this.match,rev:this.state.moves,log:this.state.log,votes:[this.localVote,this.remoteVote],playing:this.ready,hostRole:this.host?this.role:3-this.role};}
  attachWatcher(conn){
    const entry={lastSeen:Date.now(),heartbeat:null};this.watchers.set(conn,entry);
    const remove=()=>{clearInterval(entry.heartbeat);this.watchers.delete(conn);};
    const send=message=>{try{if(conn.open)conn.send({...message,version:VERSION});}catch{remove();conn.close();}};
    conn.on('open',()=>{
      if(this.closed||!this.watchers.has(conn)){conn.close();return;}
      entry.lastSeen=Date.now();send({...this.snapshot(),spectator:true});
      entry.heartbeat=setInterval(()=>{
        if(Date.now()-entry.lastSeen>6000){remove();conn.close();return;}
        send({type:'ping'});
      },1000);
    });
    conn.on('data',message=>{
      if(this.closed||!this.watchers.has(conn)||message?.version!==VERSION)return;
      entry.lastSeen=Date.now();
      if(message.type==='ping')send({type:'pong'});
      if(message.type==='sync')send({...this.snapshot(),spectator:true});
      // Watchers never enter the move or rematch handlers.
    });
    conn.on('close',remove);conn.on('error',()=>{remove();conn.close();});
  }
  attach(conn){
    this.conn=conn;
    conn.on('open',()=>{
      if(this.closed||this.conn!==conn)return;
      this.lastSeen=Date.now();clearInterval(this.heartbeat);
      this.heartbeat=setInterval(()=>{
        if(this.closed||this.conn!==conn)return;
        if(Date.now()-this.lastSeen>6000){lost();conn.close();return;}
        this.send({type:'ping'});
      },1000);
      if(this.host){this.guestToken=conn.metadata.token;this.ready=true;clearTimeout(this.timeout);this.sendSnapshot();this.status('友達と接続しました。あなたは先攻（黒）です。');}
      else this.send({type:'sync'});
    });
    conn.on('data',message=>{if(!this.closed&&this.conn===conn)this.receive(message);});
    const lost=()=>{if(this.closed||this.conn!==conn)return;this.conn=null;this.ready=false;this.pending=false;this.localVote=false;this.remoteVote=false;clearTimeout(this.timeout);clearInterval(this.heartbeat);if(this.host)this.sendSnapshot();this.status(this.spectator?'観戦の接続が切れました。再接続してください。':'友達との接続が切れました。画面を開いたまま再接続してください。');};
    conn.on('close',lost);conn.on('error',lost);
  }
  send(message){if(!this.conn?.open)return false;try{this.conn.send({...message,version:VERSION});return true;}catch{this.ready=false;this.pending=false;this.status('送信できませんでした。再接続してください。');return false;}}
  sendSnapshot(){
    const snapshot=this.snapshot(),sent=this.send(snapshot);
    for(const [conn,entry] of this.watchers){if(!conn.open)continue;try{conn.send({...snapshot,spectator:true});}catch{clearInterval(entry.heartbeat);this.watchers.delete(conn);conn.close();}}
    return sent;
  }
  receive(message){
    if(!message||message.version!==VERSION)return;
    this.lastSeen=Date.now();
    if(message.type==='ping'){this.send({type:'pong'});return;}
    if(message.type==='pong')return;
    if(message.type==='rejected'){this.send({type:'rejected-ack'});this.ready=false;clearTimeout(this.timeout);clearInterval(this.heartbeat);const conn=this.conn;this.conn=null;this.status('この部屋は満員、または別の対局が進行中です。新しい招待リンクをもらってください。');conn?.close();return;}
    if(this.host){
      if(message.type==='sync'){this.sendSnapshot();return;}
      if(message.type==='move'&&this.ready){
        const out=acceptMove(this.state,message,3-this.role,this.match);
        if(out){this.state=out.state;this.localVote=false;this.remoteVote=false;this.sendSnapshot();this.onState(this.state,out.steps);}
        else this.sendSnapshot();
      }else if(message.type==='rematch'&&this.ready&&message.match===this.match){this.remoteVote=true;this.maybeRematch();}
    }else if(message.type==='state'&&typeof message.match==='string'&&message.match.length<100&&Number.isInteger(message.rev)){
      if(message.match===this.match&&message.rev<this.rev)return;
      const state=restore(message.log);if(!state||state.moves!==message.rev)return;
      const hostRole=message.hostRole??1;if(hostRole!==1&&hostRole!==2)return;
      if(message.spectator===true){this.spectator=true;this.role=0;}
      if(!this.spectator)this.role=3-hostRole;
      let steps=[];
      if(this.match===message.match&&state.moves===this.state.moves+1)steps=play(this.state,state.log.at(-1))?.steps??[];
      this.match=message.match;this.rev=message.rev;this.state=state;this.ready=true;this.pending=false;clearTimeout(this.timeout);
      this.playing=message.playing===true;
      this.localVote=!this.spectator&&message.votes?.[1]===true;this.remoteVote=!this.spectator&&message.votes?.[0]===true;
      this.onState(state,steps);this.voteStatus();
    }
  }
  move(action){
    if(!this.canMove)return false;
    const message={type:'move',action,match:this.match,rev:this.state.moves,version:VERSION};
    if(this.host){const out=acceptMove(this.state,message,this.role,this.match);if(!out)return false;
      this.state=out.state;this.localVote=false;this.remoteVote=false;this.sendSnapshot();this.onState(this.state,out.steps);
    }else{if(!play(this.state,action))return false;this.pending=true;if(!this.send(message))return false;this.status('手を送信しています…');}
    return true;
  }
  rematch(){if(!this.ready||this.spectator)return;this.localVote=true;if(this.host)this.maybeRematch();else{this.send({type:'rematch',match:this.match});this.voteStatus();}}
  maybeRematch(){
    if(this.localVote&&this.remoteVote){this.match=uid();this.state=initial();this.localVote=false;this.remoteVote=false;this.sendSnapshot();this.onState(this.state,[]);}
    else this.sendSnapshot();
    this.voteStatus();
  }
  voteStatus(){this.status(this.spectator?(this.playing?'観戦中です。':'対戦相手の接続を待っています。'):this.localVote?'もう一局を希望しました。友達の返事を待っています。':this.remoteVote?'友達がもう一局を希望しています。「もう一局」で始めます。':`友達と接続しました。あなたは${this.role===1?'先攻（黒）':'後攻（白）'}です。`);}
  retry(){
    if(this.closed||this.ready)return;
    if(this.host&&this.peer&&!this.peer.destroyed){if(this.peer.disconnected)this.peer.reconnect();else this.status(this.invite?'招待リンクを友達に送ってください。':'接続を準備しています…');return;}
    const old=this.peer;this.peer=null;this.conn=null;old?.destroy();this.start(this.target,this.spectator);
  }
  close(){this.closed=true;this.attempt++;clearTimeout(this.timeout);clearInterval(this.heartbeat);this.ready=false;for(const [conn,entry] of this.watchers){clearInterval(entry.heartbeat);conn.close();}this.watchers.clear();this.conn?.close();this.peer?.destroy();}
}
