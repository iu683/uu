(function () {

    /* ========= CSS ========= */
    const style = document.createElement('style');
    style.textContent = `
        #ip-bar{
            position:fixed;
            left:50%;
            bottom:12px;
            transform:translateX(-50%) translateY(0);
            z-index:9999;
            font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto;
            transition: opacity 1s ease, transform 1s ease;
        }
        .ip-inner{
            position:relative;
            display:inline-flex;
            align-items:center;
            gap:10px;
            padding:8px 16px;
            border-radius:999px;
            background:rgba(255,255,255,.1);
            backdrop-filter:blur(16px);
            -webkit-backdrop-filter:blur(16px);
            box-shadow:0 8px 30px rgba(0,0,0,.15);
            font-size:14px;
        }
        .ip-inner::before{
            content:"";
            position:absolute;
            inset:0;
            padding:2px;
            border-radius:999px;
            background:linear-gradient(45deg,#ff0000,#ff7300,#fffb00,#48ff00,#00ffd5,#002bff,#7a00ff,#ff00c8,#ff0000);
            background-size:400%;
            animation:glow 20s linear infinite;
            -webkit-mask:linear-gradient(#fff 0 0) content-box,linear-gradient(#fff 0 0);
            -webkit-mask-composite:xor;
            mask-composite:exclude;
            pointer-events:none;
        }
        @keyframes glow{
            0%{background-position:0 0}
            50%{background-position:400% 0}
            100%{background-position:0 0}
        }
        .ip-icon{
            width:14px;
            height:14px;
            border-radius:50%;
            background:#1a73e8;
        }
        .ip-text{
            font-weight:600;
            white-space:nowrap;
            background:linear-gradient(45deg,#ff0000,#ff7300,#fffb00,#48ff00,#00ffd5,#002bff,#7a00ff,#ff00c8,#ff0000);
            background-size:400%;
            -webkit-background-clip:text;
            -webkit-text-fill-color:transparent;
            animation:glow 20s linear infinite;
        }
        @media(max-width:600px){
            .ip-inner{
                padding:4px 10px;
                font-size:12px;
            }
            .ip-text{
                font-size:12px;
            }
            .ip-icon{
                width:10px;
                height:10px;
            }
        }
    `;
    document.head.appendChild(style);

    /* ========= 功能 ========= */

    function isIPv4(ip){
        return ip && ip.includes(".") && !ip.includes(":");
    }

    function getIP(){
        return fetch("https://api.ip.sb/geoip")
            .then(r=>r.json())
            .then(d=>({
                ip:d.ip||"",
                country:d.country||"",
                city:d.city||"",
                isp:d.isp||""
            }));
    }

    function createBar(){
        if(document.getElementById("ip-bar")) return;
        const bar=document.createElement("div");
        bar.id="ip-bar";
        bar.innerHTML=`
            <div class="ip-inner">
                <div class="ip-icon"></div>
                <div class="ip-text" id="ip-val">Loading...</div>
            </div>`;
        document.body.appendChild(bar);
        return bar;
    }

    function init(){
        const bar = createBar();
        const el=document.getElementById("ip-val");

        getIP().then(res=>{
            const ip=res.ip;
            const loc=[res.country,res.city].filter(Boolean).join(" · ");
            const isp=res.isp;

            if(isIPv4(ip)){
                el.textContent=loc?`Your IP: ${ip} · ${loc} · ${isp}`:`Your IP: ${ip}`;
            }else{
                el.textContent=loc?`IPv6 Network · ${loc} · ${isp}`:`IPv6 Network`;
            }
        }).catch(()=>{
            el.textContent="Unable to get IP";
        });

        // 5秒后淡出 + 向下滑动
        setTimeout(()=>{
            if(bar){
                bar.style.opacity = "0";
                bar.style.transform = "translateX(-50%) translateY(20px)";
                bar.addEventListener("transitionend",()=>{
                    if(bar && bar.parentNode){
                        bar.parentNode.removeChild(bar);
                    }
                }, {once:true});
            }
        },5000);
    }

    if(document.readyState==="loading"){
        document.addEventListener("DOMContentLoaded",init);
    }else{
        init();
    }

})();
