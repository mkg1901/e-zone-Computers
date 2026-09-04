'use client';
import {useEffect,useRef,useState} from 'react';
import {createRecoveryClient,passwordRecovery} from '@/lib/supabase/password-recovery';

export function LoginPanel({busy,error,onLogin}:{busy:boolean;error:string;onLogin:(event:React.FormEvent<HTMLFormElement>)=>Promise<void>}){
 const[reset,setReset]=useState(false),[message,setMessage]=useState('');
 return <div className="login"><div className="loginCard"><div className="brandmark">e-ZONE COMPUTERS</div><h1>EZR System</h1>{reset?<PasswordReset onBack={()=>setReset(false)} onComplete={()=>{setReset(false);setMessage('Password updated. Sign in with your new password.')}}/>:<><p>Inventory, sales and accounts management</p>{message&&<div className="authNotice" role="status">{message}</div>}{error&&<div className="error" role="alert">{error}</div>}<form onSubmit={onLogin}><div className="field"><label htmlFor="login-email">Email</label><input id="login-email" name="email" type="email" autoComplete="username" required/></div><div className="field" style={{marginTop:11}}><label htmlFor="login-password">Password</label><input id="login-password" name="password" type="password" autoComplete="current-password" required/></div><button className="button" disabled={busy}>{busy?'Signing in…':'Sign In'}</button></form><button className="button secondary" type="button" disabled={busy} onClick={()=>{setMessage('');setReset(true)}}>Reset password with email OTP</button></>}</div></div>;
}
export function PasswordReset({onBack,onComplete}:{onBack:()=>void;onComplete:()=>void}){
 const[recovery]=useState(()=>passwordRecovery(createRecoveryClient()));
 const[step,setStep]=useState<'email'|'code'|'password'>('email'),[email,setEmail]=useState(''),[code,setCode]=useState(''),[password,setPassword]=useState(''),[confirm,setConfirm]=useState(''),[error,setError]=useState(''),[notice,setNotice]=useState(''),[busy,setBusy]=useState(false),[cooldown,setCooldown]=useState(0);const pending=useRef(false);
 useEffect(()=>()=>{void recovery.cancel()},[recovery]);
 useEffect(()=>{if(cooldown<=0)return;const timer=setTimeout(()=>setCooldown(c=>Math.max(0,c-1)),1000);return()=>clearTimeout(timer)},[cooldown]);
 async function run(action:()=>Promise<void>){if(pending.current)return;pending.current=true;setBusy(true);setError('');try{await action()}catch(e){setError(e instanceof Error?e.message:'Could not complete this request. Please try again.')}finally{pending.current=false;setBusy(false)}}
 async function send(){await recovery.send(email.trim().toLowerCase());setCode('');setCooldown(60);setStep('code');setNotice('If this email has an account, a code has been sent. Check your inbox and spam folder.');}
 return <><p>{step==='email'?'Reset your password using your registered email address.':step==='code'?`Enter the code sent to ${email.trim()}.`:'Choose your new password.'}</p>{notice&&<div className="authNotice" role="status">{notice}</div>}{error&&<div className="error" role="alert">{error}</div>}<form onSubmit={e=>{e.preventDefault();void run(async()=>{if(step==='email'){await send();return}if(step==='code'){await recovery.verify(email.trim().toLowerCase(),code.trim());setCode('');setNotice('Email verified. Set your new password below.');setStep('password');return}if(password!==confirm)throw Error('The passwords do not match.');await recovery.update(password);setPassword('');setConfirm('');onComplete()})}}>
 <fieldset className="saleFields" disabled={busy}>
 {step==='email'&&<div className="field"><label htmlFor="reset-email">Registered email / Gmail</label><input id="reset-email" type="email" autoComplete="email" value={email} onChange={e=>setEmail(e.target.value)} required autoFocus/></div>}
 {step==='code'&&<div className="field"><label htmlFor="reset-code">Email OTP</label><input id="reset-code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]+" value={code} onChange={e=>setCode(e.target.value.replace(/\D/g,''))} required autoFocus/></div>}
 {step==='password'&&<><div className="field"><label htmlFor="reset-password">New password</label><input id="reset-password" type="password" autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)} required autoFocus/></div><div className="field" style={{marginTop:11}}><label htmlFor="reset-confirm">Confirm new password</label><input id="reset-confirm" type="password" autoComplete="new-password" value={confirm} onChange={e=>setConfirm(e.target.value)} required/></div></>}
 <button className="button" type="submit">{busy?'Please wait…':step==='email'?'Send OTP':step==='code'?'Verify OTP':'Save new password'}</button>
 </fieldset></form>
 {step==='code'&&<button className="button secondary" type="button" disabled={busy||cooldown>0} onClick={()=>void run(send)}>{cooldown>0?`Resend code in ${cooldown}s`:'Resend code'}</button>}
 <button className="button secondary" type="button" disabled={busy} onClick={()=>void run(async()=>{await recovery.cancel();onBack()})}>Back to sign in</button></>;
}
