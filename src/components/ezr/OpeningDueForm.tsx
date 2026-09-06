'use client';
import {useState} from 'react';
import {todayISO} from '@/lib/ezr-utils';
import type {Customer} from '@/types/ezr';
import {SearchPicker} from './SearchPicker';

export function OpeningDueForm({customers,sellers,onSave}:{customers:Customer[];sellers:Customer[];onSave:(fd:FormData)=>Promise<void>}){
 const[kind,setKind]=useState<'customer'|'seller'>('customer'),[partyId,setPartyId]=useState('');
 const people=kind==='customer'?customers:sellers;
 return <form onSubmit={async e=>{e.preventDefault();await onSave(new FormData(e.currentTarget))}}><div className="grid2">
  <div className="field"><label>Due Type</label><select name="partyKind" value={kind} onChange={e=>{setKind(e.target.value as 'customer'|'seller');setPartyId('')}}><option value="customer">Customer owes us</option><option value="seller">We owe seller</option></select></div>
  <SearchPicker key={kind} name="partyId" label={kind==='customer'?'Customer':'Seller'} required value={partyId} onChange={setPartyId} options={people.map(p=>({id:p.id,label:p.name,detail:[p.phone,p.address].filter(Boolean).join(' · '),search:p.id}))}/>
  <div className="field"><label>Opening Due Amount (₹)</label><input name="amount" type="number" min="0.01" step="0.01" required/></div>
  <div className="field"><label>Due Date</label><input name="date" type="date" max={todayISO()} defaultValue={todayISO()} required/></div>
  <div className="field" style={{gridColumn:'1/-1'}}><label>Note (optional)</label><textarea name="note" rows={3} placeholder="Reason or old reference"/></div>
 </div><div className="modalActions"><button className="button" type="submit">Add Opening Due</button></div></form>;
}
