"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function ChatbotScript() {
  useEffect(() => {
    if (started) return;
    started = true;
    run();
  }, []);
  return null;
}

function run() {
const onReady = (fn) => fn();

onReady(function(){






  
  var faq = [
    { keys:['inscri','înscri','inregistr','înregistr','cum particip','cum intru','register','sign up','join'], answer:'Poți înregistra un club din pagina Înregistrare. După înregistrare, adaugi echipe din profilul clubului. Membrii individuali își pot crea un profil din „Intră într-o echipă”.' },
    { keys:['regul','rule','regulation'], answer:'Vezi pagina Reguli pentru regulile generale și cele ale probei de sezon. Poți descărca și regulamentul complet în format PDF.' },
    { keys:['proba ora','etapa ora','prima etap','etapa 1','local','city challenge','stage 1'], answer:'Fiecare echipă îndeplinește aceeași misiune în orașul ei. Sarcina, punctajul și termenul sunt identice peste tot, deci rezultatele se pot compara direct.' },
    { keys:['final','piatra','neamt','neamț','etapa 2','stage 2'], answer:'Cele mai bune echipe din proba orașului merg în finala live de la Piatra Neamț, unde concurează față în față.' },
    { keys:['premi','bani','castig','câștig','voucher','prize','reward','money'], answer:'Câștigătorii primesc premii în bani și vouchere de la sponsori. Fiecare echipă fondatoare primește o recunoaștere permanentă.' },
    { keys:['contest','apel','appeal','dispute'], answer:'Echipele pot depune cel mult 3 contestații pe eveniment, indicând un moment precis din transmisiunea live. După 3 contestații respinse, nu mai sunt acceptate altele.' },
    { keys:['punct','scor','gril','arbitr','juriu','score','rubric','judge'], answer:'Arbitrii punctează echipele la Inovație, Execuție tehnică, Prezentare și Lucru în echipă (1-10 fiecare, maximum 40). Punctajele mai multor arbitri se mediază.' },
    { keys:['transmis','live','urmar','urmăr','stream','watch'], answer:'Finala va fi transmisă live pe pagina Live. Tot acolo vor apărea și transmisiunile din proba orașului.' },
    { keys:['lucrar','trimit','incarc','încarc','submit','upload'], answer:'Autentifică-te în pagina Lucrări cu contul clubului ca să încarci lucrările echipei înainte de termen.' },
    { keys:['diplom','certificat','cert'], answer:'Diplomele se generează automat după ce rezultatele devin finale. O descarci din pagina Diplome.' },
    { keys:['forum','discut','comunitat','community'], answer:'Forumul are categoriile General, Robotică, Programare, Design și Anunțuri. Oricine poate deschide subiecte și poate răspunde.' },
    { keys:['speaker','partener','sponsor','partner'], answer:'Speakerii aduc probleme reale din companiile lor, pe care echipele le rezolvă. Partenerii și sponsorii susțin evenimentul cu finanțare și resurse. Ambii se pot înscrie din pagina Participă.' },
    { keys:['cost','tax','pret','preț','gratuit','fee','price','free'], answer:'Taxa de înscriere este mică, iar echipele care au nevoie pot primi sprijin.' },
    { keys:['cati membri','câți membri','marimea echipei','mărimea echipei','membr','team size','how many'], answer:'Echipele pot avea mărimi diferite. Fiecare club poate avea mai multe echipe, în categorii diferite (Robotică, Programare, Design etc.).' },
    { keys:['termen','cand','când','data','deadline','when'], answer:'Vezi pagina Evenimente pentru datele actuale. Cronometrul de pe prima pagină arată timpul rămas până la finala de la Piatra Neamț.' },
    { keys:['salut','buna','bună','hello','hey'], answer:'Salut! Întreabă-mă orice despre IMPULS și o să te ajut cât pot de bine.' },
  ];

  function botReply(input){
    var lower = input.toLowerCase();
    for(var i = 0; i < faq.length; i++){
      for(var j = 0; j < faq[i].keys.length; j++){
        if(lower.indexOf(faq[i].keys[j]) !== -1) return faq[i].answer;
      }
    }
    return 'Încă nu știu să răspund la asta. Întreabă-mă despre înscriere, reguli, proba orașului, punctaj, contestații sau premii. Sau vezi întrebările frecvente de pe prima pagină!';
  }

  var msgs = document.getElementById('chat-messages');
  var chatInput = document.getElementById('chat-input');

  function addMsg(text, isUser){
    var div = document.createElement('div');
    div.className = isUser ? 'user-msg' : 'bot-msg';
    div.textContent = text;
    msgs.appendChild(div);
    msgs.scrollTop = msgs.scrollHeight;
  }

  function send(){
    var val = chatInput.value.trim();
    if(!val) return;
    addMsg(val, true);
    chatInput.value = '';
    setTimeout(function(){ addMsg(botReply(val), false); }, 400);
  }

  document.getElementById('chat-send').addEventListener('click', send);
  chatInput.addEventListener('keydown', function(e){ if(e.key === 'Enter') send(); });
    
});
}
