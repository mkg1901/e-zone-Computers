'use client';
import {useEffect,useState} from 'react';
export type Theme='light'|'black';
const storageKey=(userId:string)=>`ezr-theme:${userId}`;
export function useTheme(userId?:string):[Theme,(theme:Theme)=>void]{
 const [theme,setTheme]=useState<Theme>('light');
 useEffect(()=>{
  let saved:Theme='light';
  try{if(userId&&localStorage.getItem(storageKey(userId))==='black')saved='black';}catch{}
  setTheme(saved);document.documentElement.dataset.theme=saved;
 },[userId]);
 function choose(next:Theme){
  setTheme(next);document.documentElement.dataset.theme=next;
  try{if(userId)localStorage.setItem(storageKey(userId),next);}catch{}
 }
 return [theme,choose];
}
export function ThemeSettings({theme,onChange}:{theme:Theme;onChange:(theme:Theme)=>void}){
 return <><div className="sectionHead"><h3>Theme</h3></div><p className="muted">Choose your appearance. Your choice is remembered for your account in this browser.</p><div className="themeProfiles" role="group" aria-label="Theme profiles">{(['light','black'] as const).map(value=><button type="button" key={value} className={`themeProfile ${theme===value?'selected':''}`} aria-pressed={theme===value} onClick={()=>onChange(value)}><span className={`themePreview ${value}`} aria-hidden="true"><span className="previewSidebar"><i/><i/><i/></span><span className="previewMain"><i/><span><i/><i/><i/></span><i/></span></span><span className="themeProfileName"><b>{value==='light'?'Light':'Black'}</b><span>{theme===value?'Selected':'Use theme'}</span></span><span className="themeDescription">{value==='light'?'Original light appearance.':'Dark navy surfaces with cyan accents.'}</span></button>)}</div></>;
}
