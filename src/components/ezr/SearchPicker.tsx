'use client';
import {useId,useState} from 'react';
export type SearchOption={id:string;label:string;detail?:string;search?:string};
export function SearchPicker({label,name,options,required=false,onChange,value}:{label:string;name?:string;options:SearchOption[];required?:boolean;onChange?:(id:string)=>void;value?:string}){
 const uid=useId(),[query,setQuery]=useState(''),[selected,setSelected]=useState(''),[open,setOpen]=useState(false),[active,setActive]=useState(0);
 const id=value??selected,choice=options.find(o=>o.id===id);
 const results=options.filter(o=>`${o.label} ${o.detail||''} ${o.search||''}`.toLowerCase().includes(query.trim().toLowerCase()));
 const pick=(option:SearchOption)=>{setSelected(option.id);onChange?.(option.id);setQuery('');setOpen(false);setActive(0)};
 return <div className="field searchPicker" onBlur={e=>{if(!e.currentTarget.contains(e.relatedTarget))setOpen(false)}}>
  <label htmlFor={uid}>{label}</label><input type="hidden" name={name} value={id}/>
  <input id={uid} role="combobox" aria-expanded={open} aria-controls={`${uid}-results`} aria-autocomplete="list" aria-activedescendant={open&&results[active]?`${uid}-${active}`:undefined} autoComplete="off" required={required} value={open?query:choice?.label||query} placeholder={`Search ${label.toLowerCase()}…`} onFocus={()=>{setQuery('');setOpen(true)}} onChange={e=>{setQuery(e.target.value);setSelected('');onChange?.('');setOpen(true);setActive(0)}} onKeyDown={e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();setOpen(true);setActive(i=>Math.max(0,Math.min(results.length-1,i+(e.key==='ArrowDown'?1:-1))))}if(e.key==='Enter'&&open){e.preventDefault();if(results[active])pick(results[active])}if(e.key==='Escape'){e.preventDefault();setOpen(false)}}}/>
  {open&&<div className="searchOptions" role="listbox" id={`${uid}-results`}>{results.length?results.map((o,i)=><button type="button" role="option" aria-selected={i===active} id={`${uid}-${i}`} className={i===active?'active':''} key={o.id} onMouseDown={e=>e.preventDefault()} onClick={()=>pick(o)}><b>{o.label}</b>{o.detail&&<small>{o.detail}</small>}</button>):<div className="empty">No matches. Try another search.</div>}</div>}
 </div>;
}
