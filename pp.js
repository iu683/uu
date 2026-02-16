(function () {
    // 1. 动态注入 CSS 样式
    const style = document.createElement("style");
    style.textContent = `
        #ip-bar {
            position: fixed;
            left: 50%;
            bottom: 12px;
            transform: translateX(-50%);
            z-index: 9999;
            transition: transform 0.4s cubic-bezier(0.25,0.8,0.25,1), opacity 0.4s ease;
            opacity: 1;
            font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
        }
        #ip-bar.ip-hide {
            transform: translate(-50%,150%);
            opacity: 0;
            pointer-events: none;
        }
        .ip-inner {
            position: relative;
            display: inline-flex;
            align-items: center;
            gap: 10px;
            padding: 8px 16px;
            border-radius: 999px;
            background: rgba(255,255,255,0.1);
            box-shadow: 0 8px 30px rgba(0,0,0,0.15);
            backdrop-filter: blur(16px);
            -webkit-backdrop-filter: blur(16px);
        }
        .ip-inner::before {
            content: "";
            position: absolute;
            inset: 0;
            border-radius: 999px;
            padding: 2px;
            background: linear-gradient(45deg,#ff0000,#ff7300,#fffb00,#48ff00,#00ffd5,#002bff,#7a00ff,#ff00c8,#ff0000);
            background-size: 400%;
            animation: glowing-ip 20s linear infinite;
            -webkit-mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
            -webkit-mask-composite: xor;
            mask-composite: exclude;
            pointer-events: none;
        }
        @keyframes glowing-ip {
            0% { background-position: 0 0; }
            50% { background-position: 400% 0; }
            100% { background-position: 0 0; }
        }
        .ip-text {
            font-size: 14px;
            font-weight: 600;
            white-space: nowrap;
        }
    `;
    document.head.appendChild(style);

    function isIPv4(ip) {
        return ip && ip.includes(".") && !ip.includes(":");
    }

    // 带超时 fetch（Edge 稳定）
    function fetchWithTimeout(url, timeout = 4000) {
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject("timeout"), timeout);
            fetch(url, { cache: "no-store" })
                .then(res => {
                    clearTimeout(timer);
                    if (!res.ok) throw new Error("HTTP error");
                    return res.json();
                })
                .then(resolve)
                .catch(reject);
        });
    }

    function getIP() {
        return Promise.any([
            fetchWithTimeout("https://ipapi.co/json/").then(d => ({
                ip: d.ip,
                country: d.country_name,
                city: d.city
            })),
            fetchWithTimeout("https://ipinfo.io/json").then(d => ({
                ip: d.ip,
                country: d.country,
                city: d.city || d.region
            }))
        ]);
    }

    function createBar() {
        if (document.getElementById("ip-bar")) return;
        const bar = document.createElement("div");
        bar.id = "ip-bar";
        bar.innerHTML = `
            <div class="ip-inner">
                <div class="ip-text"><span id="ip-val">Loading...</span></div>
            </div>`;
        document.body.appendChild(bar);
    }

    function init() {
        createBar();
        const el = document.getElementById("ip-val");

        getIP()
            .then(res => {
                const ip = res.ip || "";
                const country = res.country || "";
                const city = res.city || "";
                const loc = country && city && country !== city
                    ? `${country} - ${city}`
                    : (country || city);

                if (isIPv4(ip))
                    el.textContent = loc ? `Your IP: ${ip} · ${loc}` : `Your IP: ${ip}`;
                else
                    el.textContent = loc ? `IPv6 Network · ${loc}` : `IPv6 Network`;
            })
            .catch(() => {
                el.textContent = "Unable to retrieve IP";
            });

        // 滚动隐藏逻辑
        let lastScrollTop = 0;
        window.addEventListener("scroll", function () {
            const bar = document.getElementById("ip-bar");
            if (!bar) return;
            const scrollTop = window.pageYOffset || document.documentElement.scrollTop;
            if (scrollTop > lastScrollTop && scrollTop > 50) {
                bar.classList.add("ip-hide");
            } else {
                bar.classList.remove("ip-hide");
            }
            lastScrollTop = scrollTop <= 0 ? 0 : scrollTop;
        }, { passive: true });
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init);
    } else {
        init();
    }
})();
