const express=require('express'),crypto=require('crypto'),bcrypt=require('bcryptjs'),fs=require('fs'),path=require('path');

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

app.listen(PORT,()=>console.log('Air Combat on '+PORT));