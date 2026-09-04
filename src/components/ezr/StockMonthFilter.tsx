'use client';
import {monthLabel,todayISO} from '@/lib/ezr-utils';
export function StockMonthFilter({value,onChange,dates}:{value:string;onChange:(value:string)=>void;dates:string[]}){
 const months=[...new Set([todayISO().slice(0,7),...(value?[value]:[]),...dates.filter(Boolean).map(d=>d.slice(0,7))])].sort().reverse();
 return <label className="stockMonthFilter">Sold month <select value={value} onChange={e=>onChange(e.target.value)}><option value="">All months</option>{months.map(m=><option key={m} value={m}>{monthLabel(m)}</option>)}</select></label>;
}
