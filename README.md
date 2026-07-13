# WOL-wake-desktop

透過 **Tailscale SSH** 遠端連上 Raspberry Pi Zero 1WH（代號 **Tomori**），
再由它發送 **Wake-on-LAN 魔術封包**喚醒桌機。這個 repo 的目的是讓 Tomori 在
SD 卡重刷後可以幾分鐘內恢復到可用狀態。

## 硬體 / 網路資訊

| 項目 | 值 |
|---|---|
| 裝置 | Tomori (Raspberry Pi Zero 1WH, ARMv6) |
| 作業系統 | Raspberry Pi OS Lite |
| 桌機 MAC | `50:EB:F6:5C:CE:3E` |
| 廣播位址 | `192.168.0.255` |
| WoL 指令 | `wakeonlan -i 192.168.0.255 50:EB:F6:5C:CE:3E` |

## 目錄結構

```
.
├── setup.sh                     # 一鍵部署腳本
├── wol-api/
│   └── server.py                # 輕量 HTTP API（純標準庫，無外部依賴）
├── configs/
│   ├── wol-api.service          # systemd unit
│   └── wol-api.env.example      # 環境變數範例（token / MAC / broadcast / port）
└── README.md
```

## 重刷後的復原步驟

1. **燒錄系統**
   用 Raspberry Pi Imager 燒錄 Raspberry Pi OS Lite（32-bit，因為 Pi Zero 1WH
   是 ARMv6，無法跑 64-bit）。在 Imager 的進階設定（齒輪圖示）裡先設定好：
   - hostname（例如 `tomori`）
   - 啟用 SSH（可先用密碼或既有金鑰，之後改用 Tailscale SSH）
   - Wi-Fi（如果不是接網路線）

2. **第一次開機、確認能連線**
   透過區網 SSH 先連進去一次，確認開機正常、能上網。

3. **Clone 本 repo 並執行部署腳本**
   ```bash
   git clone https://github.com/Underiger/WOL-wake-desktop.git
   cd WOL-wake-desktop
   sudo ./setup.sh
   ```
   `setup.sh` 會依序：
   - `apt update` / `full-upgrade`
   - 安裝 `wakeonlan`、`log2ram`（透過 azlux repo，減少 SD 卡寫入以延長壽命）
   - 安裝 Tailscale（官方 install script）
   - 建立系統帳號 `wolapi`，把 `wol-api/server.py` 部署到 `/opt/wol/server.py`
   - 產生 `/etc/wol-api.env`（若不存在，會自動產生隨機 token，並設定 mode 600）
   - 安裝並啟用 `wol-api.service`（systemd，開機自動啟動）

4. **加入 Tailscale（手動步驟）**
   腳本跑完後會提示執行：
   ```bash
   sudo tailscale up
   ```
   照畫面上的連結在瀏覽器完成登入，並到 Tailscale 後台 admin console 核准這台裝置。
   之後就可以直接用 Tailscale 的 hostname/IP 做 SSH 或呼叫 API。

5. **記下 API token**
   腳本最後會印出 `WOL_TOKEN`（存在 `/etc/wol-api.env`，權限 600、只有 root 能讀）。
   將這個 token 儲存到呼叫端（iOS 捷徑、shell script 等）即可，
   呼叫端會自動帶入，日常使用不需手動輸入。

## 使用方式

健康檢查（不需要 token）：
```bash
curl http://<tomori-tailscale-ip>:8080/status
```

喚醒桌機：
```bash
curl -X POST http://<tomori-tailscale-ip>:8080/wake \
  -H "Authorization: Bearer <你的 WOL_TOKEN>"
```

## 維運 / 除錯

```bash
sudo systemctl status wol-api      # 服務狀態
sudo journalctl -u wol-api -f      # 即時 log
sudo systemctl restart wol-api     # 重啟服務
```

若要更改目標 MAC / 廣播位址 / port / token，編輯 `/etc/wol-api.env` 後
`sudo systemctl restart wol-api` 即可，不需要重新部署。

## 安全性備註

- API 只監聽在 Tailscale 網路上使用即可，**不要**把 8080 port 對外 port-forward
  到公網。
- `wol-api.service` 以獨立的低權限系統帳號 `wolapi` 執行，並開啟
  `ProtectSystem=strict` 等 systemd 安全選項。
- `/etc/wol-api.env` 權限為 `600`（root 專屬），token 不會寫死在程式碼或
  service 檔裡。
