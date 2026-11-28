import { createClient } from "npm:@supabase/supabase-js@2";
const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply = (body: unknown, status=200) => new Response(JSON.stringify(body), {status, headers:{...cors,"Content-Type":"application/json"}});
async function digest(code: string, secret: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), {name:"HMAC",hash:"SHA-256"}, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(code));
  return Array.from(new Uint8Array(sig), b => b.toString(16).padStart(2,"0")).join("");
}
Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok",{headers:cors});
  if (req.method !== "POST") return reply({error:"Method not allowed"},405);
  const url=Deno.env.get("SUPABASE_URL"), srv=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), resend=Deno.env.get("RESEND_API_KEY"), recipient=Deno.env.get("RESEND_TEST_EMAIL");
  if(!url||!srv||!resend||!recipient) return reply({error:"Server configuration incomplete"},500);
  const bearer=(req.headers.get("Authorization")||"").match(/^Bearer\s+(.+)$/i);
  if(!bearer) return reply({error:"Authentication required"},401);
  const db=createClient(url,srv,{auth:{persistSession:false,autoRefreshToken:false}});
  try {
    const {data:{user},error:authErr}=await db.auth.getUser(bearer[1]);
    if(authErr||!user) return reply({error:"Invalid session"},401);
    const body=await req.json().catch(()=>({}));
    const {data:owners,error:ownerErr}=await db.from("restaurant_users").select("restaurant_id").eq("user_id",user.id).in("role",["owner","admin"]).limit(1);
    if(ownerErr) return reply({error:"Unable to verify permissions"},500);
    const restaurantId=owners?.[0]?.restaurant_id;
    if(!restaurantId) return reply({error:"Owner/Admin access required"},403);
    if(body.action==="request") {
      if(typeof body.restaurant_user_id!=="string") return reply({error:"Select a staff account"},400);
      const {data:target,error:targetErr}=await db.from("restaurant_users").select("id,restaurant_id,role").eq("id",body.restaurant_user_id).maybeSingle();
      if(targetErr) return reply({error:"Unable to verify staff"},500);
      if(!target||String(target.role).toLowerCase()!=="staff"||target.restaurant_id!==restaurantId) return reply({error:"Staff account not found"},403);
      const {data:recent,error:rateErr}=await db.from("staff_pin_reset_otp_challenges").select("last_sent_at").eq("owner_user_id",user.id).eq("target_restaurant_user_id",target.id).is("consumed_at",null).order("created_at",{ascending:false}).limit(1);
      if(rateErr) return reply({error:"Unable to check request limit"},500);
      if(recent?.[0]&&Date.now()-new Date(recent[0].last_sent_at).getTime()<60000) return reply({error:"Wait 60 seconds before requesting another code."},429);
      const otp=String(crypto.getRandomValues(new Uint32Array(1))[0]%1000000).padStart(6,"0");
      const otpHash=await digest(otp,resend);
      const expires=new Date(Date.now()+600000).toISOString();
      const {data:challenge,error:insertErr}=await db.from("staff_pin_reset_otp_challenges").insert({owner_user_id:user.id,restaurant_id:restaurantId,target_restaurant_user_id:target.id,otp_hash:otpHash,expires_at:expires,attempts:0}).select("id").single();
      if(insertErr||!challenge) return reply({error:"Unable to create OTP challenge"},500);
      const sent=await fetch("https://api.resend.com/emails",{method:"POST",headers:{"Authorization":"Bearer "+resend,"Content-Type":"application/json"},body:JSON.stringify({from:"EDMEL POS Test <onboarding@resend.dev>",to:[recipient],subject:"EDMEL POS — Staff PIN reset verification code",html:"<h2>EDMEL POS verification code</h2><p>Your test verification code is:</p><p style=\"font-size:30px;font-weight:bold;letter-spacing:8px\">"+otp+"</p><p>Expires in 10 minutes. One use only.</p><p><strong>Testing mode:</strong> sent to the configured Resend test inbox, not necessarily the Owner/Admin login email.</p>"})});
      if(!sent.ok){await db.from("staff_pin_reset_otp_challenges").delete().eq("id",challenge.id);return reply({error:"Resend could not send the test OTP",provider_status:sent.status},502);}
      return reply({success:true,challenge_id:challenge.id,expires_in_seconds:600,message:"OTP sent to configured Resend test inbox."});
    }
    if(body.action==="verify") {
      if(typeof body.challenge_id!=="string"||typeof body.otp!=="string"||!/^\d{6}$/.test(body.otp)) return reply({error:"Enter the six-digit code"},400);
      const otpHash=await digest(body.otp,resend);
      const {data:status,error:verifyErr}=await db.rpc("verify_staff_pin_reset_otp",{p_challenge_id:body.challenge_id,p_owner_user_id:user.id,p_otp_hash:otpHash});
      if(verifyErr) return reply({error:"Unable to verify code"},500);
      if(status!=="verified") return reply({error:status==="expired"?"Code expired. Request another.":status==="locked"?"Too many attempts. Request another code.":status==="used"?"Code already used.":"Incorrect code."},400);
      return reply({success:true,challenge_id:body.challenge_id,message:"OTP verified."});
    }
    return reply({error:"Action must be request or verify"},400);
  } catch { return reply({error:"Unable to process OTP request"},500); }
});