export type CapacityType='RAM'|'SSD'|'HDD';
export function capacityTypeForAccessory(value:string):CapacityType|null{const key=value.trim().toLowerCase().replace(/[-_]+/g,' ').replace(/\s+/g,' ');if(key==='ram'||key==='memory')return 'RAM';if(key==='ssd'||key==='nvme'||key==='ssd nvme'||key==='ssd/nvme'||key==='ssd / nvme')return 'SSD';if(key==='hdd'||key==='hard disk'||key==='hard drive')return 'HDD';return null;}
export const capacityUnit=(type:CapacityType)=>type==='HDD'?1000:1024;
export function parseCapacity(value:string|undefined,type:CapacityType){
 if(!value)return null;const match=value.trim().match(/^([\d.]+)\s*(TB|GB)?\b\s*(.*)$/i);if(!match)return null;const number=Number(match[1]);if(!Number.isFinite(number)||number<0)return null;return{gb:(match[2]||'GB').toUpperCase()==='TB'?number*capacityUnit(type):number,suffix:(match[3]||'').trim()};
}
export function formatCapacity(gb:number,type:CapacityType,suffix=''){
 if(gb<=0)return '';const unit=capacityUnit(type),display=type!=='RAM'&&gb>=unit?`${Number((gb/unit).toFixed(10))}TB`:`${Math.round(gb*100)/100}GB`;return display+(suffix?' '+suffix:'');
}
export function assertCapacityGb(type:CapacityType,gb:number,allowZero=false){if(!Number.isInteger(gb)||gb<0||(!allowZero&&gb===0))throw Error(`${type} must be a positive whole number in GB.`);if(type==='RAM'&&gb%2!==0)throw Error('RAM must be a multiple of 2 GB.');if(type==='SSD'&&gb!==0&&gb%120!==0&&gb%128!==0)throw Error('SSD must be a multiple of 120 GB or 128 GB.');if(type==='HDD'&&gb%250!==0)throw Error('HDD must be a multiple of 250 GB.');return gb;}
export function validateOldStockCapacity(type:CapacityType,raw:FormDataEntryValue|null){
 const text=String(raw||'').trim();if(!text)return '';if(!/^\d+$/.test(text))throw Error(`${type} must be entered as a whole number in GB.`);const gb=Number(text);assertCapacityGb(type,gb);return formatCapacity(gb,type);
}
