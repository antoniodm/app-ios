import Capacitor
import WebKit

class MainViewController: CAPBridgeViewController {

    // Iniettato a document-start: intercetta setTimeout(biometricLogin, 800) del PHP
    // così quando scatta chiama window.biometricLogin() in modo dinamico (il nostro override)
    private let setTimeoutInterceptJS = #"""
    (function(){
    if(window._grST)return;window._grST=1;
    var _o=window.setTimeout;
    window.setTimeout=function(fn,d,a){
      if(window.biometricLogin&&fn===window.biometricLogin){
        return _o(function(){window.biometricLogin();},d);
      }
      return _o.apply(this,arguments);
    };
    })()
    """#

    // Iniettato a document-end: gestione multi-account biometrico
    private let multiAccountJS = #"""
    (function(){
    if(window._grM)return;window._grM=1;
    if(!window.Capacitor||!window.Capacitor.isNativePlatform||!window.Capacitor.isNativePlatform()){return;}
    var P=window.Capacitor.Plugins.Preferences;
    if(!P){return;}

    if(window.biometricLogin&&document.getElementById('frmlogin')){
      var _origBio=window.biometricLogin;
      (async function(){
        var al=await P.get({key:'bio_autologin'});
        if(al.value!=='1')return;
        await P.remove({key:'bio_autologin'});
        var ru=await P.get({key:'bio_username'});
        var rp=await P.get({key:'bio_password'});
        if(!ru.value||!rp.value)return;
        var hasPsw=!!document.getElementById('psw');
        var lf=document.getElementById('login')||document.querySelector('input[name=login]');
        if(hasPsw){
          if(lf)lf.value=ru.value;
          document.getElementById('psw').value=rp.value;
          document.getElementById('frmlogin').submit();
        }else{
          sessionStorage.setItem('bioPending','1');
          if(lf)lf.value=ru.value;
          document.getElementById('frmlogin').submit();
        }
      })();

      var frm=document.getElementById('frmlogin');
      frm.addEventListener('submit',function(){
        var u=(document.getElementById('login')||document.querySelector('input[name=login]')||{}).value;
        var p=(document.getElementById('psw')||{}).value;
        if(u)localStorage.setItem('_grPU',u);
        if(p)localStorage.setItem('_grPP',p);
      });

      window.biometricLogin=async function(){
        var r=await P.get({key:'bio_accounts'});
        var accs=[];
        if(r.value)try{accs=JSON.parse(r.value);}catch(e){}
        if(accs.length<=1){return _origBio();}
        var Bio=window.Capacitor.Plugins.BiometricAuthNative;
        if(!Bio){return _origBio();}
        try{
          await Bio.internalAuthenticate({
            reason:'Accedi a Guardroom24',cancelTitle:'Usa password',
            allowDeviceCredential:true
          });
        }catch(e){return;}
        var ov=document.createElement('div');
        ov.id='_grPickerOverlay';
        ov.style.cssText='position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.55);z-index:99999;display:flex;align-items:center;justify-content:center';
        var bx=document.createElement('div');
        bx.style.cssText='background:#fff;border-radius:12px;padding:24px;min-width:280px;max-width:90%;box-shadow:0 4px 32px rgba(0,0,0,.3)';
        bx.innerHTML='<h4 style="margin:0 0 16px;text-align:center;color:#1a1a1a;font-size:18px">Seleziona account</h4>';
        accs.forEach(function(acc){
          var b=document.createElement('button');
          b.textContent=acc.username;
          b.style.cssText='display:block;width:100%;padding:14px;margin:8px 0;border:2px solid #448CCB;border-radius:8px;background:#fff;color:#448CCB;font-size:16px;cursor:pointer;text-align:center;font-weight:500';
          b.onclick=function(){
            var o=document.getElementById('_grPickerOverlay');
            if(o)o.parentNode.removeChild(o);
            _grDoLogin(acc);
          };
          bx.appendChild(b);
        });
        var cb=document.createElement('button');
        cb.textContent='Annulla';
        cb.style.cssText='display:block;width:100%;padding:10px;margin:12px 0 0;border:none;background:transparent;color:#888;font-size:14px;cursor:pointer';
        cb.onclick=function(){var o=document.getElementById('_grPickerOverlay');if(o)o.parentNode.removeChild(o);};
        bx.appendChild(cb);
        ov.appendChild(bx);
        ov.onclick=function(e){if(e.target===ov){var o=document.getElementById('_grPickerOverlay');if(o)o.parentNode.removeChild(o);}};
        document.body.appendChild(ov);
      };

      async function _grDoLogin(acc){
        await P.set({key:'bio_username',value:acc.username});
        await P.set({key:'bio_password',value:acc.password});
        await P.set({key:'bio_totp_secret',value:acc.totp_secret||''});
        await P.set({key:'bio_pending_login_otp',value:'1'});
        var hasPsw=!!document.getElementById('psw');
        var lf=document.getElementById('login')||document.querySelector('input[name=login]');
        if(hasPsw){
          if(lf)lf.value=acc.username;
          document.getElementById('psw').value=acc.password;
          document.getElementById('frmlogin').submit();
        }else{
          sessionStorage.setItem('bioPending','1');
          if(lf)lf.value=acc.username;
          document.getElementById('frmlogin').submit();
        }
      }
    }

    if(typeof window.saveBiometricCredentials==='function'){
      var _origSave=window.saveBiometricCredentials;
      window.saveBiometricCredentials=async function(){
        await _origSave();
        try{
          var ru=await P.get({key:'bio_username'});
          if(!ru.value)return;
          var rp=await P.get({key:'bio_password'});
          var rt=await P.get({key:'bio_totp_secret'});
          var r=await P.get({key:'bio_accounts'});
          var a=[];if(r.value)try{a=JSON.parse(r.value);}catch(e){}
          var i=a.findIndex(function(x){return x.username===ru.value;});
          var e={username:ru.value,password:rp.value||'',totp_secret:rt.value||''};
          if(i>=0)a[i]=e;else a.push(e);
          await P.set({key:'bio_accounts',value:JSON.stringify(a)});
        }catch(ex){}
      };
    }

    window._grSaveAccount=async function(user,pass){
      try{
        await P.set({key:'bio_username',value:user});
        await P.set({key:'bio_password',value:pass});
        var rt=await P.get({key:'bio_totp_secret'});
        var r=await P.get({key:'bio_accounts'});
        var a=[];if(r.value)try{a=JSON.parse(r.value);}catch(e){}
        var i=a.findIndex(function(x){return x.username===user;});
        var entry={username:user,password:pass,totp_secret:rt.value||''};
        if(i>=0)a[i]=entry;else a.push(entry);
        await P.set({key:'bio_accounts',value:JSON.stringify(a)});
        if(typeof $('#GrBioSetupModal')!=='undefined')$('#GrBioSetupModal').modal('hide');
      }catch(ex){}
    };

    var onDash=window.location.pathname.indexOf('dashboard')!==-1;
    if(onDash){
      var AppSet=window.Capacitor&&window.Capacitor.Plugins&&window.Capacitor.Plugins.AppSettings;
      if(AppSet&&AppSet.autoRegisterToken){
        AppSet.autoRegisterToken().catch(function(){});
      }
    }

    var pu=localStorage.getItem('_grPU');
    var pp=localStorage.getItem('_grPP');
    if(pu&&pp&&onDash){
      localStorage.removeItem('_grPU');
      localStorage.removeItem('_grPP');
      (async function(){
        try{
          var Bio=window.Capacitor.Plugins.BiometricAuthNative;
          if(!Bio){return;}
          var ck=await Bio.checkBiometry();
          if(!ck.isAvailable)return;
          var r=await P.get({key:'bio_accounts'});
          var a=[];if(r.value)try{a=JSON.parse(r.value);}catch(e){}
          if(a.length===0){
            var ru=await P.get({key:'bio_username'});
            if(ru.value){
              var rp2=await P.get({key:'bio_password'});
              var rt2=await P.get({key:'bio_totp_secret'});
              a=[{username:ru.value,password:rp2.value||'',totp_secret:rt2.value||''}];
              await P.set({key:'bio_accounts',value:JSON.stringify(a)});
            }
          }
          var idx=a.findIndex(function(x){return x.username===pu;});
          if(idx>=0){
            a[idx].password=pp;
            await P.set({key:'bio_accounts',value:JSON.stringify(a)});
            return;
          }
          if(a.length===0){return;}
          window._grPendingUser=pu;
          window._grPendingPass=pp;
          setTimeout(function(){
            if(typeof dynModal!=='function')return;
            dynModal('GrBioSetup','Accesso rapido',
              '<p>Vuoi salvare l\'account <strong>'+window._grPendingUser.replace(/[<>&]/g,'')+'</strong> per l\'accesso biometrico?</p>'
              +'<div class="text-center mt-3">'
              +'<button class="btn btn--primary" onclick="window._grSaveAccount(window._grPendingUser,window._grPendingPass);"><i class="fas fa-fingerprint"></i> S\u00ec, salva</button>'
              +'<button class="btn btn--ghost ml-2" data-dismiss="modal">No grazie</button>'
              +'</div>','','','0','modal-sm');
          },1800);
        }catch(ex){}
      })();
    }
    })()
    """#

    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(ExoPlayerPlugin())
        bridge?.registerPluginInstance(AppSettingsPlugin())
        webView?.allowsBackForwardNavigationGestures = true

        let ucc = webView?.configuration.userContentController
        ucc?.addUserScript(WKUserScript(
            source: setTimeoutInterceptJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        ucc?.addUserScript(WKUserScript(
            source: multiAccountJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        guard top > 0, let wv = webView else { return }
        wv.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top)
    }
}
