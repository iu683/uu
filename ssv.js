(function(){
  const style = document.createElement("style");
  style.textContent = `
#music-ball {
  position: fixed;
  bottom: 50px;
  left: 50px;
  width: 45px;
  height: 45px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.2);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
  box-shadow: 0 4px 12px rgba(0,0,0,0.3);
  cursor: pointer;
  z-index: 9999;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: transform 0.2s, background 0.3s;
  overflow: hidden;
}
#music-ball:hover { transform: scale(1.1); }
@keyframes rotate { 0%{transform:rotate(0)}100%{transform:rotate(360deg)} }
.rotating { animation: rotate 5s linear infinite; }
#music-controls {
  position: fixed;
  display: none;
  flex-direction: column;
  align-items: center;
  background: rgba(255,255,255,0.2);
  padding: 12px 16px;
  border-radius: 16px;
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
  z-index: 9999;
  max-width: 80%;
  box-shadow: 0 4px 16px rgba(0,0,0,0.2);
}
#music-controls button {
  background: rgba(255,255,255,0.15);
  border: none;
  color: #fff;
  cursor: pointer;
  font-size: 20px;
  margin: 5px;
  padding: 6px 10px;
  border-radius: 10px;
  transition: background 0.2s;
}
#music-controls button:hover { background: rgba(255,255,255,0.3); }
#music-info { color: #000; font-size: 14px; margin-top: 4px; text-align: center; word-break: break-word; }
#progress-bar { width:100%;height:4px;background:rgba(255,255,255,0.3);margin-top:8px;border-radius:2px;overflow:hidden; }
#progress { width:0;height:100%;background:#4caf50;border-radius:2px; }
#lyrics { max-height:100px;overflow-y:auto;color:#FFA500;font-size:12px;margin-top:8px;text-align:center;line-height:1.4; }
@media (max-width: 768px) {
  #music-ball { width:50px;height:50px; }
  #music-controls button { font-size:18px;margin:4px; }
  #music-info { font-size:12px; }
  #lyrics { font-size:10px;max-height:80px; }
}`;
  document.head.appendChild(style);

  document.body.insertAdjacentHTML("beforeend", `
    <div id="music-ball"></div>
    <div id="music-controls">
      <div>
        <button id="prev">⏮️</button>
        <button id="play-pause">▶️</button>
        <button id="next">⏭️</button>
      </div>
      <div id="music-info">加载中...</div>
      <div id="progress-bar"><div id="progress"></div></div>
      <div id="lyrics">歌词加载中...</div>
    </div>
  `);

  const songs = [
  { "name": "打上花火", "artist": "打上花火", "url": "https://sa.otg.dpdns.org/mp3/%E6%89%93%E4%B8%8A%E8%8A%B1%E7%81%AB.mp3", "cover": "https://sa.otg.dpdns.org/cover/%E6%89%93%E4%B8%8A%E8%8A%B1%E7%81%AB.jpg", "lrc": "https://sa.otg.dpdns.org/lrc/%E6%89%93%E4%B8%8A%E8%8A%B1%E7%81%AB.lrc" }
];
  let currentSongIndex = Math.floor(Math.random() * songs.length);
  let audio = new Audio(), isPlaying = false, hasInteracted = false, lyricsArr = [];
  const ball=document.getElementById('music-ball'),controls=document.getElementById('music-controls'),
        info=document.getElementById('music-info'),playBtn=document.getElementById('play-pause'),
        progress=document.getElementById('progress'),lyricsDiv=document.getElementById('lyrics');

  async function loadLyrics(url){try{const t=await(await fetch(url)).text();lyricsArr=t.split("\n").map(l=>{const m=l.match(/\[(\d+):(\d+)(?:\.(\d+))?\](.*)/);return m?{time:+m[1]*60+ +m[2]+(m[3]?+m[3]/1000:0),text:m[4]}:null}).filter(Boolean);}catch(e){lyricsArr=[]}}
  function updateLyrics(){if(!lyricsArr.length)return lyricsDiv.textContent="暂无歌词";let ct=audio.currentTime,txt="";for(let i=0;i<lyricsArr.length;i++){if(ct>=lyricsArr[i].time)txt=lyricsArr[i].text;else break}lyricsDiv.textContent=txt}
  function updateSong(){const s=songs[currentSongIndex];info.textContent=s.name+" - "+s.artist;ball.style.background=`url('${s.cover}') center/cover no-repeat`;loadLyrics(s.lrc);}
  async function playSong(){try{audio.src=songs[currentSongIndex].url;await audio.play();isPlaying=true;playBtn.textContent="⏸️";ball.classList.add("rotating");}catch(e){isPlaying=false;ball.classList.remove("rotating");}}
  function pauseSong(){audio.pause();isPlaying=false;playBtn.textContent="▶️";ball.classList.remove("rotating");}
  function togglePlay(){isPlaying?pauseSong():playSong();}
  async function nextSong(){currentSongIndex=(currentSongIndex+1)%songs.length;updateSong();await playSong();}
  async function prevSong(){currentSongIndex=(currentSongIndex-1+songs.length)%songs.length;updateSong();await playSong();}
  function firstInteraction(){if(hasInteracted)return;hasInteracted=true;playSong();}
  window.addEventListener("click",firstInteraction,{once:true});
  window.addEventListener("keydown",firstInteraction,{once:true});
  ball.addEventListener("click",()=>{controls.style.display=controls.style.display==="flex"?"none":"flex";const r=ball.getBoundingClientRect();controls.style.left=Math.min(r.left,window.innerWidth-controls.offsetWidth)+"px";controls.style.top=Math.max(r.top-controls.offsetHeight-10,10)+"px"});
  playBtn.addEventListener("click",togglePlay);
  document.getElementById("next").addEventListener("click",nextSong);
  document.getElementById("prev").addEventListener("click",prevSong);
  audio.addEventListener("ended",nextSong);
  let ox=0,oy=0,drag=false;
  function startDrag(e){drag=true;const cx=e.touches?e.touches[0].clientX:e.clientX,cy=e.touches?e.touches[0].clientY:e.clientY;ox=cx-ball.offsetLeft;oy=cy-ball.offsetTop;}
  function moveDrag(e){if(!drag)return;const cx=e.touches?e.touches[0].clientX:e.clientX,cy=e.touches?e.touches[0].clientY:e.clientY;let l=cx-ox,t=cy-oy;l=Math.max(0,Math.min(window.innerWidth-ball.offsetWidth,l));t=Math.max(0,Math.min(window.innerHeight-ball.offsetHeight,t));ball.style.left=l+"px";ball.style.top=t+"px";ball.style.bottom="auto";ball.style.right="auto";if(controls.style.display==="flex"){controls.style.left=Math.min(l,window.innerWidth-controls.offsetWidth)+"px";controls.style.top=Math.max(t-controls.offsetHeight-10,10)+"px";}}
  function endDrag(){drag=false;}
  ball.addEventListener("mousedown",startDrag);ball.addEventListener("touchstart",startDrag,{passive:true});
  document.addEventListener("mousemove",moveDrag);document.addEventListener("touchmove",moveDrag,{passive:false});
  document.addEventListener("mouseup",endDrag);document.addEventListener("touchend",endDrag);
  audio.addEventListener("timeupdate",()=>{if(audio.duration)progress.style.width=(audio.currentTime/audio.duration*100)+"%";updateLyrics();});
  updateSong();playSong();
})();
