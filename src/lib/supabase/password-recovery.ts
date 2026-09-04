import {createClient,type SupabaseClient} from '@supabase/supabase-js';

// Recovery sessions stay in memory and never replace the normal app login session.
export function createRecoveryClient(){
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
 if(!url||!key)throw Error('Missing Supabase environment variables.');
 return createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false,storageKey:'ezr-password-recovery'}});
}
export function passwordRecovery(client:SupabaseClient){
 let verifiedUserId:string|null=null;
 return {
  async send(email:string){verifiedUserId=null;await client.auth.signOut({scope:'local'});const{error}=await client.auth.resetPasswordForEmail(email);if(error)throw error;},
  async verify(email:string,token:string){
   verifiedUserId=null;
   const{data,error}=await client.auth.verifyOtp({email,token,type:'recovery'});
   if(error)throw error;
   if(!data.user||!data.session)throw Error('The code could not be verified. Request a new code.');
   const{data:profile,error:profileError}=await client.from('profiles').select('id').eq('id',data.user.id).single();
   if(profileError||!profile){await client.auth.signOut({scope:'local'});throw Error('This account has no EZR profile. Contact the Admin.');}
   verifiedUserId=data.user.id;
  },
  async update(password:string){
   if(!verifiedUserId)throw Error('Verify your email code before setting a password.');
   const{data,error}=await client.auth.getUser();
   if(error||data.user?.id!==verifiedUserId){verifiedUserId=null;throw Error('Verification expired. Please request a new code.');}
   const result=await client.auth.updateUser({password});if(result.error)throw result.error;
   verifiedUserId=null;
   await client.auth.signOut({scope:'local'});
  },
  async cancel(){verifiedUserId=null;await client.auth.signOut({scope:'local'});}
 };
}
