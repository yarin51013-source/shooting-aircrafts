const express=require('express'),crypto=require('crypto'),bcrypt=require('bcryptjs'),fs=require('fs'),path=require('path'),http=require('http'),{WebSocketServer}=require('ws');

const app=express();
const PORT=process.env.PORT||3000;
const DB=path.join(__dirname,'data.json');
const SALT=process.env.IP_HASH_SALT||'CHANGE_ME_BEFORE_PUBLIC_DEPLOY';

app.use(express.json({limit:'20kb'}));
app.use(express.static(path.join(__dirname,'public')));

function db(){
  try{return JSON.parse(fs.readFileSync(DB,'utf8'))}
  catch{return {users:[]}}
}
function save(x){fs.writeFileSync(DB,JSON.stringify(x,null,2))}
function ip(req){
  const x=String(req.headers['x-forwarded-for']||req.socket.remoteAddress||'unknown').split(',')[0].trim();
  return crypto.createHash('sha256').update(x+'|'+SALT).digest('hex');
}

app.post('/api/auth',async(req,res)=>{
  const email=String(req.body.email||'').trim().toLowerCase();
  const pass=String(req.body.password||'');
  if(!/^\S+@\S+\.\S+$/.test(email)) return res.status(400).json({error:'Enter a valid email.'});
  if(pass.length<8) return res.status(400).json({error:'Password must be at least 8 characters.'});

  const d=db();
  let u=d.users.find(x=>x.email===email);
  const now=new Date().toISOString();

  if(!u){
    u={
      id:crypto.randomUUID(),
      email,
      passwordHash:await bcrypt.hash(pass,12),
      createdAt:now,
      lastSeen:now,
      ipHash:ip(req),
      visits:1
    };
    d.users.push(u);
  }else{
    if(!await bcrypt.compare(pass,u.passwordHash)) return res.status(401).json({error:'Invalid email or password.'});
    u.lastSeen=now;
    u.ipHash=ip(req);
    u.visits=(u.visits||0)+1;
  }

  save(d);
  res.json({ok:true,user:{id:u.id,email:u.email}});
});

app.get('/api/health',(q,r)=>r.json({ok:true}));

app.get('/privacy',(q,r)=>r.send(`<!doctype html>
<meta name="viewport" content="width=device-width">
<style>
body{font:16px system-ui;max-width:800px;margin:40px auto;padding:20px;background:#07101d;color:#eee;line-height:1.6}
a{color:#7dd3fc}
</style>
<h1>Privacy Notice</h1>
<p>Email is used for player accounts. Normal web requests include an IP address; this starter stores only a salted cryptographic hash for security and abuse prevention. Passwords are bcrypt hashes. Raw IPs are not displayed in the game.</p>
<p>For a serious public launch, use a managed database, secure sessions, a defined retention policy, and a complete privacy/compliance review.</p>
<a href="/">Back</a>`));


const httpServer=http.createServer(app);
const wss=new WebSocketServer({server:httpServer,path:'/street-legends'});
const players=new Map();
let raceState=null;
function broadcastRace(){const payload={type:'race',race:raceState};for(const client of wss.clients)send(client,payload);}
function publicRace(){return raceState?JSON.parse(JSON.stringify(raceState)):null;}

function cleanName(value){return String(value||'Player').replace(/[<>]/g,'').replace(/[\u0000-\u001f\u007f]/g,'').trim().slice(0,18)||'Player';}
function send(ws,data){if(ws.readyState===1)ws.send(JSON.stringify(data));}
wss.on('connection',ws=>{
 const id=crypto.randomUUID();
 const player={id,name:'Player',x:0,z:12,heading:0,color:0xe52b35};
 players.set(id,player);
 send(ws,{type:'welcome',id,players:[...players.values()].filter(p=>p.id!==id),race:publicRace()});
 ws.on('message',raw=>{
  let msg;try{msg=JSON.parse(raw.toString())}catch{return}
  if(msg.type==='name'){player.name=cleanName(msg.name);if(raceState){const rp=raceState.participants.find(p=>p.id===id);if(rp)rp.name=player.name;broadcastRace();}return;}
  if(msg.type==='race-create'){
   if(raceState&&raceState.status!=='complete')return;
   const maxPlayers=Math.max(2,Math.min(8,Math.floor(Number(msg.maxPlayers)||6)));
   raceState={id:crypto.randomUUID(),status:'lobby',hostId:id,maxPlayers,laps:3,startedAt:null,participants:[{id,name:player.name,bot:false,lap:0,finished:false,time:null}]};while(raceState.participants.length<maxPlayers){const n=raceState.participants.filter(p=>p.bot).length+1;raceState.participants.push({id:'bot-'+n,name:'AI Racer '+n,bot:true,lap:0,finished:false,time:null});}broadcastRace();return;
  }
  if(msg.type==='race-join'){
   if(!raceState||raceState.status!=='lobby'||raceState.participants.some(p=>p.id===id))return;
   const botIndex=raceState.participants.findIndex(p=>p.bot);
   const human={id,name:player.name,bot:false,lap:0,finished:false,time:null};
   if(botIndex>=0){
    raceState.participants[botIndex]=human;
   }else if(raceState.participants.length<raceState.maxPlayers){
    raceState.participants.push(human);
   }else{
    send(ws,{type:'race-error',message:'Race is full.'});return;
   }
   broadcastRace();return;
  }
  if(msg.type==='race-start'&&raceState&&raceState.hostId===id&&raceState.status==='lobby'){
   raceState.status='countdown';raceState.startedAt=Date.now()+3000;broadcastRace();setTimeout(()=>{if(raceState&&raceState.status==='countdown'){raceState.status='running';raceState.startedAt=Date.now();raceState.participants.forEach((p,i)=>{if(p.bot)p.finishAfter=52+((i*17+Math.floor(Math.random()*24))%58);});broadcastRace();}},3000);return;
  }
  if(msg.type==='race-progress'&&raceState&&raceState.status==='running'){const p=raceState.participants.find(p=>p.id===id);if(p&&!p.bot)p.lap=Math.max(p.lap,Math.min(3,Number(msg.lap)||0));broadcastRace();return;}
  if(msg.type==='race-finish'&&raceState&&raceState.status==='running'){const p=raceState.participants.find(p=>p.id===id);if(p&&!p.bot&&!p.finished){p.finished=true;p.lap=3;p.time=Math.max(0,Number(msg.time)||0);p.rank=raceState.participants.filter(q=>q.finished).length;}if(raceState.participants.every(q=>q.finished))raceState.status='complete';broadcastRace();return;}
  if(msg.type==='race-leave'&&raceState){if(raceState.hostId===id){raceState=null;}else{raceState.participants=raceState.participants.filter(p=>p.id!==id);if(!raceState.participants.some(p=>!p.bot)){raceState=null;}}broadcastRace();return;}
  if(msg.type==='state'){
   const x=Number(msg.x),z=Number(msg.z),heading=Number(msg.heading);
   if(Number.isFinite(x)&&Number.isFinite(z)&&Number.isFinite(heading)){
    player.x=Math.max(-2000,Math.min(2000,x));player.z=Math.max(-2000,Math.min(2000,z));player.heading=heading;
   }
  }
 });
 ws.on('close',()=>{players.delete(id);if(raceState){raceState.participants=raceState.participants.filter(p=>p.id!==id);if(raceState.hostId===id){raceState=null;}else if(!raceState.participants.some(p=>!p.bot))raceState=null;broadcastRace();}});
 ws.on('error',()=>players.delete(id));
});
setInterval(()=>{if(!raceState||raceState.status!=='running')return;const elapsed=(Date.now()-raceState.startedAt)/1000;let changed=false;for(const p of raceState.participants){if(p.bot&&!p.finished&&Number.isFinite(p.finishAfter)&&elapsed>=p.finishAfter){p.finished=true;p.lap=3;p.time=p.finishAfter;p.rank=raceState.participants.filter(q=>q.finished).length;changed=true;}}if(raceState.participants.every(p=>p.finished)){raceState.status='complete';changed=true;}if(changed)broadcastRace();},500);
setInterval(()=>{
 const snapshot=JSON.stringify({type:'players',players:[...players.values()]});
 for(const client of wss.clients)if(client.readyState===1)client.send(snapshot);
},100);
httpServer.listen(PORT,'0.0.0.0',()=>console.log('Air Combat + Street Legends multiplayer on '+PORT));
