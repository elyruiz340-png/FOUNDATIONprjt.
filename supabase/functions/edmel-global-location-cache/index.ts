import { getTimeZones } from "npm:@vvo/tzdb";
const API = "https://api.placedb.org/v1";
const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};
const keyOf=(s:string)=>String(s||"").toLowerCase().normalize("NFD").replace(/\p{Diacritic}/gu,"").replace(/[^a-z0-9]/g,"");
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed."},405);
 const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!url||!serviceKey)return json({error:"Location cache is not configured."},500);
 let body:any;try{body=await req.json()}catch{return json({error:"Invalid JSON body."},400)}
 const action=String(body?.action||""),cc=String(body?.country_code||"").toUpperCase();
 if(!["countries","regions","region_search","cities","search","timezones"].includes(action))return json({error:"Unsupported action."},400);
 if(["regions","cities","search","timezones"].includes(action)&&!/^[A-Z]{2}$/.test(cc))return json({error:"A valid ISO alpha-2 country code is required."},400);
 const headers={apikey:serviceKey,Authorization:"Bearer "+serviceKey,"Content-Type":"application/json"};
 async function read(k:string){const r=await fetch(url+"/rest/v1/edmel_global_location_cache?cache_key=eq."+encodeURIComponent(k)+"&select=payload,expires_at",{headers});if(!r.ok)throw new Error("Unable to read location cache.");const rows=await r.json();return rows?.[0]&&Date.parse(rows[0].expires_at)>Date.now()?rows[0].payload:null}
 async function write(k:string,p:any){const r=await fetch(url+"/rest/v1/edmel_global_location_cache?on_conflict=cache_key",{method:"POST",headers:{...headers,Prefer:"resolution=merge-duplicates,return=minimal"},body:JSON.stringify({cache_key:k,payload:p,release:p?.release||p?.s_version||null,fetched_at:new Date().toISOString(),expires_at:new Date(Date.now()+30*86400000).toISOString()})});if(!r.ok)throw new Error("Unable to update location cache.")}
 async function load(k:string,path:string){const c=await read(k);if(c)return c;const r=await fetch(API+path,{headers:{Accept:"application/json"}});if(r.status===404)return null;if(!r.ok)throw new Error("Global location provider unavailable.");const p=await r.json();await write(k,p);return p}
 try{
  if(action==="countries"){const p=await load("countries","/countries.json");if(!Array.isArray(p?.countries))return json({error:"Invalid country dataset."},502);return json({countries:p.countries,release:p.release||null})}
  if(action==="regions"){const p=await load("regions:"+cc,"/regions/"+cc+".json");if(!Array.isArray(p?.regions))return json({regions:[]});return json({regions:p.regions,release:p.release||null})}
  if(action==="region_search"){
   const q=keyOf(body?.query);if(q.length<2)return json({regions:[]});
   const countries=await load("countries","/countries.json");const cached=await read("all_regions");
   let all:any[]=Array.isArray(cached?.regions)?cached.regions:[];
   if(!all.length){
    const codes=(countries?.countries||[]).map((x:any)=>String(x.code||"").toUpperCase()).filter((x:string)=>/^[A-Z]{2}$/.test(x));
    const results:any[]=[];let cursor=0;
    const workers=Array.from({length:12},async()=>{while(cursor<codes.length){const code=codes[cursor++];try{const p=await load("regions:"+code,"/regions/"+code+".json");for(const r of p?.regions||[])if(r?.name&&!r.unassigned)results.push({...r,country_code:code});}catch(_){}}});
    await Promise.all(workers);all=results;await write("all_regions",{regions:all,release:countries?.release||null});
   }
   return json({regions:all.filter(r=>keyOf(r.name).includes(q)).slice(0,80)})
  }
  if(action==="timezones"){const zones=getTimeZones({countryCode:cc}).map((z:any)=>({name:z.name,mainCities:z.mainCities||[],alternativeName:z.alternativeName||""}));return json({timezones:zones})}
  if(action==="cities"){const id=Number(body?.region_id);if(!Number.isSafeInteger(id)||id<=0)return json({error:"A valid region selection is required."},400);const p=await load("cities:"+cc+":"+id,"/cities/"+cc+"/"+id+".json");return json({settlements:p?.settlements||[],release:p?.release||null})}
  const q=String(body?.query||"").trim(),normalized=keyOf(q);if(normalized.length<2||normalized.length>40)return json({places:[]});
  let best:any=null;for(let depth=1;depth<=normalized.length;depth++){const prefix=normalized.slice(0,depth),p=await load("ac:"+cc+":"+prefix,"/ac/"+cc+"/"+prefix+".json");if(!p)break;best=p;if(p.complete===true)break}
  return json({places:Array.isArray(best?.places)?best.places.filter((p:any)=>keyOf(p?.name).startsWith(normalized)):[],release:best?.release||null,complete:best?.complete===true})
 }catch(error){return json({error:error instanceof Error?error.message:"Location lookup failed."},502)}
});