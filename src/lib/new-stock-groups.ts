import type {NewStockProduct} from '@/types/ezr';
import {inr} from './ezr-utils';
export const productKey=(p:NewStockProduct)=>JSON.stringify([p.accessoryType,p.brand,p.modelNo].map(x=>x.trim().toLowerCase()));
export const oldestFirst=(a:NewStockProduct,b:NewStockProduct)=>a.purchaseDate.localeCompare(b.purchaseDate)||(a.createdAt||'').localeCompare(b.createdAt||'')||String(a.id).localeCompare(String(b.id),undefined,{numeric:true});
export type ProductGroup=NewStockProduct&{batches:NewStockProduct[];maxPrice:number;unserializedQuantity:number};
export function groupProducts(products:NewStockProduct[]):ProductGroup[]{
 const groups=new Map<string,NewStockProduct[]>();
 for(const p of products){const key=productKey(p);groups.set(key,[...(groups.get(key)||[]),p]);}
 return [...groups.entries()].map(([key,rows])=>{
  const batches=[...rows].sort(oldestFirst),first=batches[0];
  const serials=batches.flatMap(p=>[...p.serials].sort((a,b)=>(a.createdAt||'').localeCompare(b.createdAt||'')||String(a.id).localeCompare(String(b.id),undefined,{numeric:true})));
  const unserializedQuantity=batches.reduce((sum,p)=>sum+(p.serialRequired?0:Math.max(0,p.quantity-p.serials.filter(s=>!s.sold).length)),0);
  return {...first,id:key,batches,serials,quantity:batches.reduce((n,p)=>n+p.quantity,0),purchasePrice:Math.min(...batches.map(p=>p.purchasePrice)),maxPrice:Math.max(...batches.map(p=>p.purchasePrice)),sellerName:[...new Set(batches.map(p=>p.sellerName?.trim()||'—'))].join(', '),serialRequired:unserializedQuantity===0,unserializedQuantity};
 });
}
export const purchaseRange=(p:ProductGroup)=>p.purchasePrice===p.maxPrice?inr(p.purchasePrice):`${inr(p.purchasePrice)} – ${inr(p.maxPrice)}`;
export function allocateProduct(group:ProductGroup,quantity:number,rate:number,serialNumbers:string[]){
 if(!Number.isInteger(quantity)||quantity<1||quantity>group.quantity)throw Error('Enter an available whole-number quantity.');
 if(new Set(serialNumbers).size!==serialNumbers.length||serialNumbers.length>quantity)throw Error('Check the selected serial numbers.');
 const selected=new Set(serialNumbers),found=new Set<string>();let remaining=quantity-serialNumbers.length;
 const lines=group.batches.map(p=>{
  const serials=p.serials.filter(s=>!s.sold&&selected.has(s.serialNumber)).map(s=>s.serialNumber);serials.forEach(sn=>found.add(sn));
  const available=p.serialRequired?0:Math.max(0,p.quantity-p.serials.filter(s=>!s.sold).length);
  const take=Math.min(remaining,available);remaining-=take;
  if(take+serials.length>p.quantity)throw Error('Stock changed. Refresh and select the item again.');
  return {new_product_id:p.id,quantity:take+serials.length,unit_price:rate,serial_numbers:serials};
 }).filter(line=>line.quantity>0);
 if(found.size!==selected.size)throw Error('A selected serial is unavailable. Refresh and select again.');
 if(remaining)throw Error(`Select at least ${Math.max(0,quantity-group.unserializedQuantity)} serial numbers for this quantity.`);
 return lines;
}
