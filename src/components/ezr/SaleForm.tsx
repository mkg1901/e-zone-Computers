'use client';
import {useEffect,useRef,useState} from 'react';
import {allocateProduct,groupProducts,purchaseRange,type ProductGroup} from '@/lib/new-stock-groups';
import {ContactPicker} from './ContactPicker';
import {inr,todayISO} from '@/lib/ezr-utils';
import type {Bank,Customer,NewStockProduct,Stock} from '@/types/ezr';

type ItemDraft={key:number;productId:string;quantity:string;price:string;serials:string[]};
export function SaleForm({customers,banks,legacy,newStock,onSave}:{customers:Customer[];banks:Bank[];legacy:Stock[];newStock:NewStockProduct[];onSave:(fd:FormData)=>Promise<void>}){
 const pending=useRef(false),nextKey=useRef(1);
 const[submitting,setSubmitting]=useState(false);
 const[source,setSource]=useState<'legacy'|'new'>('legacy');
 const[mode,setMode]=useState('Cash');
 const[legacyPrice,setLegacyPrice]=useState('');
 const[service,setService]=useState('0');
 const[items,setItems]=useState<ItemDraft[]>([]);
 const[query,setQuery]=useState(''),[active,setActive]=useState(0),[error,setError]=useState('');
 const catalog=groupProducts(newStock.filter(p=>p.quantity>0));
 const matches=catalog.filter(p=>`${p.batches.map(b=>b.id).join(' ')} ${p.accessoryType} ${p.brand} ${p.modelNo} ${p.serials.filter(s=>!s.sold).map(s=>s.serialNumber).join(' ')}`.toLowerCase().includes(query.trim().toLowerCase()));
 const[draft,setDraft]=useState<ItemDraft|null>(null),[itemError,setItemError]=useState('');
 const searchInput=useRef<HTMLInputElement>(null);
 useEffect(()=>{if(source==='new'&&!draft)searchInput.current?.focus()},[source,draft]);
 const selectedProduct=draft?catalog.find(p=>p.id===draft.productId):undefined;
 const selectProduct=(product:ProductGroup)=>{const existing=items.find(r=>r.productId===product.id);const serial=product.serials.find(s=>!s.sold&&s.serialNumber.toLowerCase()===query.trim().toLowerCase());setDraft(existing?{...existing,serials:[...existing.serials]}:{key:nextKey.current++,productId:product.id,quantity:serial?'1':'',price:'',serials:serial?[serial.serialNumber]:[]});setItemError('');setError('')};
 const changeDraft=(patch:Partial<ItemDraft>)=>{setDraft(row=>row?{...row,...patch}:null);setItemError('')};
 const closeItem=()=>{setDraft(null);setItemError('');setQuery('');setActive(0)};
 const addToBill=()=>{if(!draft||!selectedProduct)return;const quantity=Number(draft.quantity),price=Number(draft.price);if(!Number.isInteger(quantity)||quantity<1||quantity>selectedProduct.quantity){setItemError('Enter an available whole-number quantity.');return}if(!draft.price.trim()||!Number.isFinite(price)||price<0||Math.abs(price*100-Math.round(price*100))>0.000001){setItemError('Enter a valid selling rate with up to two decimal places.');return}try{allocateProduct(selectedProduct,quantity,price,draft.serials)}catch(e){setItemError((e as Error).message);return}setItems(rows=>rows.some(r=>r.key===draft.key)?rows.map(r=>r.key===draft.key?draft:r):[...rows,draft]);closeItem();setError('')};
 const subtotal=items.reduce((sum,row)=>sum+Math.round(Number(row.price||0)*100)*Number(row.quantity||0),0)/100;
 const total=source==='new'?(Math.round(subtotal*100)+Math.round(Number(service||0)*100))/100:Number(legacyPrice||0);
 return <form className={source==='new'?'newBilling':undefined} onSubmit={async e=>{e.preventDefault();if(pending.current)return;const fd=new FormData(e.currentTarget);if(source==='new'&&draft){setError('Add the selected item to the bill, or cancel it before saving.');return}if(source==='new'&&(!items.length||!fd.get('buyer'))){setError('Select a buyer and add at least one item.');return}if(source==='new'&&items.some(r=>catalog.find(p=>p.id===r.productId)?.serialRequired&&r.serials.length!==Number(r.quantity))){setError('Select one serial number for every unit of a serialized item.');return}setError('');if(source==='new'){try{fd.set('items',JSON.stringify(items.flatMap(row=>{const product=catalog.find(p=>p.id===row.productId);if(!product)throw Error('Stock changed. Remove the unavailable item and select again.');return allocateProduct(product,Number(row.quantity),Number(row.price),row.serials)})))}catch(e){setError((e as Error).message);return}}pending.current=true;setSubmitting(true);try{await onSave(fd)}finally{pending.current=false;setSubmitting(false)}}}>
  <fieldset className="saleFields" disabled={submitting}>
   <div className="grid2">
    <div className="field"><label>Stock Source</label><select name="source" value={source} onChange={e=>setSource(e.target.value as 'legacy'|'new')}><option value="legacy">Old Stock</option><option value="new">New Stock</option></select></div>
    <ContactPicker kind="customer" name="buyer" label="Buyer" contacts={customers}/>
   </div>
   {source==='legacy'?<div className="grid2">
    <div className="field"><label>Stock Item</label><select name="stock" required><option value="">— select —</option>{legacy.map(s=><option key={s.id} value={s.id}>{s.id} — {s.model||s.accessoryType||s.category}</option>)}</select></div>
    <div className="field"><label>Selling Price (₹)</label><input name="price" type="number" min="0" step="0.01" value={legacyPrice} onChange={e=>setLegacyPrice(e.target.value)} required/></div>
   </div>:<>
    <div className="entryIntro"><b>New stock bill</b><span>Search and select a product, choose quantity and serials, then click Add to Bill.</span></div>
    <div className="field"><label htmlFor="bill-search">Find an item</label><input ref={searchInput} id="bill-search" type="search" disabled={!!draft} autoComplete="off" value={query} placeholder="Type item, brand, model, stock ID or serial number…" onChange={e=>{setQuery(e.target.value);setActive(0)}} onKeyDown={e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();setActive(i=>Math.max(0,Math.min(matches.length-1,i+(e.key==='ArrowDown'?1:-1))))}if(e.key==='Enter'){e.preventDefault();if(matches[active])selectProduct(matches[active])}}}/></div>
    {!draft&&<div className="catalogResults" aria-label="Matching items">{matches.map((p,i)=><button className={active===i?'active':''} type="button" key={p.id} onClick={()=>selectProduct(p)}><span><b>{p.accessoryType} · {p.brand} {p.modelNo}</b><small>{p.serialRequired?'Serial required':p.serials.some(s=>!s.sold)?'Serial and quantity stock':'Quantity stock'}</small></span><span>{p.quantity} available <strong>Select</strong></span></button>)}{!matches.length&&<div className="empty">No matching available items.</div>}</div>}
    {draft&&selectedProduct&&<div className="billItemEditor" aria-label="Selected product">
     <div className="saleLineHead"><div><h3>{selectedProduct.accessoryType} · {selectedProduct.brand} {selectedProduct.modelNo}</h3></div><button type="button" className="button secondary small" onClick={closeItem}>Cancel selection</button></div>
     <div className="selectedStockFacts"><span><b>{selectedProduct.quantity}</b> available</span><span>Purchase price / unit: <b>{purchaseRange(selectedProduct)}</b></span></div>
     {items.some(r=>r.key===draft.key)&&<p className="muted">This product is already in the bill. Update its quantity and details below.</p>}
     <div className="grid2"><div className="field"><label htmlFor="item-quantity">Quantity</label><input id="item-quantity" autoFocus type="number" min="1" step="1" max={selectedProduct.quantity} value={draft.quantity} placeholder="Enter quantity" onChange={e=>changeDraft({quantity:e.target.value,serials:draft.serials.slice(0,Math.max(0,Math.floor(Number(e.target.value))))})}/></div><div className="field"><label htmlFor="item-rate">Selling Price / Unit (₹)</label><input id="item-rate" type="number" min="0" step="0.01" value={draft.price} placeholder="Enter selling price" onChange={e=>changeDraft({price:e.target.value})}/></div></div>
     {Number.isInteger(Number(draft.quantity))&&Number(draft.quantity)>0&&Number(draft.quantity)<=selectedProduct.quantity&&<div className="itemSerialSection">{selectedProduct.serials.some(s=>!s.sold)?<><b>Serial numbers · {draft.serials.length} / {draft.quantity} selected{selectedProduct.serialRequired?' (required)':` · at least ${Math.max(0,Number(draft.quantity)-selectedProduct.unserializedQuantity)} required`}</b><SerialChoices key={draft.key} product={selectedProduct} selected={draft.serials} quantity={Number(draft.quantity)} onChange={serials=>changeDraft({serials})}/></>:<p className="muted">{selectedProduct.serialRequired?'No available serial numbers. This item cannot be added until its serials are available.':'No serial numbers for this item.'}</p>}</div>}
     {itemError&&<p className="error" role="alert">{itemError}</p>}
     <div className="itemAddRow"><button type="button" className="button" onClick={addToBill}>{items.some(r=>r.key===draft.key)?'Update Bill Item':'Add to Bill'}</button><b>Item total: {inr(Math.round(Number(draft.price||0)*100)*Number(draft.quantity||0)/100)}</b></div>
    </div>}
    <div className="sectionHead"><h3>Bill items <small>{items.length} lines</small></h3><span className="muted">{items.length?'Items added to this bill':'No items added yet'}</span></div>
    <div className="tableWrap billGrid"><table><thead><tr><th>Item</th><th>Qty</th><th>Rate / Unit (₹)</th><th>Amount</th><th>Action</th></tr></thead><tbody>{items.map(row=>{const product=catalog.find(p=>p.id===row.productId);if(!product)return <tr key={row.key}><td colSpan={5}>Item no longer available. <button type="button" className="button danger small" onClick={()=>setItems(rows=>rows.filter(r=>r.key!==row.key))}>Remove</button></td></tr>;return <tr key={row.key}><td><b>{product.accessoryType} · {product.brand} {product.modelNo}</b>{!!row.serials.length&&<small className="blockMuted">S/N: {row.serials.join(', ')}</small>}</td><td>{row.quantity}</td><td>{inr(Number(row.price))}</td><td className="billAmount">{inr(Math.round(Number(row.price)*100)*Number(row.quantity)/100)}</td><td><div className="actions"><button type="button" className="button secondary small" disabled={!!draft} onClick={()=>selectProduct(product)}>Edit</button><button type="button" className="button danger small" disabled={!!draft} onClick={()=>setItems(rows=>rows.filter(r=>r.key!==row.key))}>Remove</button></div></td></tr>})}</tbody></table>{!items.length&&<div className="empty">Select a product above, enter its details and click Add to Bill.</div>}</div>
    <div className="grid2"><div className="field"><label>Service Charge (₹, optional)</label><input name="serviceCharge" type="number" min="0" step="0.01" value={service} onChange={e=>setService(e.target.value)}/></div><div className="saleSummary"><div>Items: {inr(subtotal)}</div><b>Bill Total: {inr(total)}</b></div></div>
   </>}
   <div className="grid2">
    <div className="field"><label>Date</label><input name="date" type="date" max={todayISO()} defaultValue={todayISO()} required/></div>
    <div className="field"><label>Payment Mode</label><select name="mode" value={mode} onChange={e=>setMode(e.target.value)}><option>Cash</option><option>Online</option></select></div>
    {mode==='Online'&&<div className="field"><label>Bank</label><select name="bank" required><option value="">— select —</option>{banks.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></div>}
    <div className="field"><label>Amount Received (₹)</label><input name="received" type="number" min="0" max={Number.isFinite(total)?total:0} step="0.01" defaultValue="0"/></div>
   </div>
  </fieldset>
  {error&&<p className="error" role="alert">{error}</p>}
  <div className="modalActions"><button className="button" type="submit" disabled={submitting}>{submitting?'Saving sale…':'Save Sale & Create Invoice'}</button></div>
 </form>;
}

function SerialChoices({product,selected,quantity,onChange}:{product:NewStockProduct;selected:string[];quantity:number;onChange:(serials:string[])=>void}){
 const[query,setQuery]=useState('');const serials=product.serials.filter(s=>!s.sold&&s.serialNumber.toLowerCase().includes(query.trim().toLowerCase()));
 return <div className="serialChoices"><input aria-label={`Search serials for ${product.modelNo}`} placeholder="Find or scan a serial…" value={query} onChange={e=>setQuery(e.target.value)} onKeyDown={e=>{if(e.key==='Enter'){e.preventDefault();const match=serials.find(s=>s.serialNumber.toLowerCase()===query.trim().toLowerCase());if(match&&!selected.includes(match.serialNumber)&&selected.length<quantity){onChange([...selected,match.serialNumber]);setQuery('')}}}}/><div>{serials.map(s=><label key={s.id}><input type="checkbox" checked={selected.includes(s.serialNumber)} disabled={!selected.includes(s.serialNumber)&&selected.length>=quantity} onChange={e=>onChange(e.target.checked?[...selected,s.serialNumber]:selected.filter(sn=>sn!==s.serialNumber))}/>{s.serialNumber}</label>)}{!serials.length&&<small>No matching available serials.</small>}</div></div>;
}
