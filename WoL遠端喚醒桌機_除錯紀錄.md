# WoL 遠端喚醒桌機 — 除錯紀錄

**日期：** 2026-07-12（週日）22:30 ～ 2026-07-13 02:00  
**設備：** Tomori（Pi Zero 1WH）→ 桌機（i7-12700 / Z690 / Intel I225-V）  
**目標：** 從澎湖透過 Tailscale SSH 進 Pi Zero，發送 WoL 魔術封包喚醒家中桌機

---

## 完整遠端喚醒流程

```
ssh tomori
    ↓
金鑰自動驗證（免密碼）
    ↓
直接進入 Pi Zero
    ↓
發 WoL 魔術封包
    ↓
桌機醒來
    ↓
Moonlight 串流
```

---

## SSH 免密碼設定

編輯 `~/.ssh/config`：

```bash
nano ~/.ssh/config
```

貼入以下設定：

```
Host tomori
    HostName 100.108.245.31
    User scout
    IdentityFile ~/.ssh/id_ed25519
    AddKeysToAgent yes
```

之後直接：

```bash
ssh tomori
# → 不用密碼，金鑰自動驗證，直接進入 Pi Zero ✓
```

---

## 網路拓撲（修正前）

```
牆壁網路口 → CBN modem (192.168.0.x)
 └── AX1800HP WAN（韌體損壞，橋接/透傳模式）
     ├── LAN → 桌機: 192.168.0.211
     └── LAN → ASUS N12+ WAN（Router 模式, 192.168.50.x）
                └── WiFi (ASUS_DC) → Pi Zero: 192.168.50.26
```

**問題：** 桌機在 `192.168.0.x`，Pi Zero 在 `192.168.50.x`，雙 NAT 不同網段，WoL 廣播封包無法跨越 N12+ 的 NAT 邊界。

---

## 除錯過程

### 1. Pi Zero WiFi 連線設定

Pi Zero 使用 NetworkManager（不是 wpa_supplicant），`raspi-config` 設定 WiFi 無效。

```bash
# raspi-config 報錯
Error: No network with SSID 'ASUS_DC' found.

# 正確做法：使用 nmcli
sudo nmcli device wifi rescan
nmcli device wifi list                              # 確認 ASUS_DC 可見
sudo nmcli device wifi connect "ASUS_DC" password "密碼"
# → Device 'wlan0' successfully activated
```

遇到 `802-11-wireless-security.key-mgmt: property is missing` 錯誤時，刪除舊連線重建：

```bash
sudo nmcli connection delete "ASUS_DC"
sudo nmcli device wifi connect "ASUS_DC" password "密碼"
```

### 2. 發現雙 NAT 問題

```bash
# Pi Zero
ip route
# → default via 192.168.50.1 ... src 192.168.50.26

# 桌機 (Windows)
ipconfig
# → IPv4: 192.168.0.211, 閘道: 192.168.0.1
```

Pi Zero 在 `192.168.50.x`（N12+ 的 LAN），桌機在 `192.168.0.x`（CBN modem 的 LAN）。不同網段。

### 3. WoL 封包送出但桌機無反應

```bash
sudo apt install etherwake -y
sudo etherwake -i wlan0 50:EB:F6:5C:CE:3E          # 無反應

sudo apt install wakeonlan -y
wakeonlan -i 192.168.50.255 50:EB:F6:5C:CE:3E      # 封包送出但跨不了網段
```

### 4. 解法：N12+ 改為 AP 模式

進入 N12+ 管理介面（`192.168.50.1`）：

1. 系統管理 → 運作模式
2. 選擇「無線存取點（Access Point）」
3. 自動取得內網 IP → 是
4. WiFi SSID / 密碼維持不變 → 套用

改完後 N12+ 重開機，不再做 NAT / DHCP，純粹當 WiFi 天線。

### 5. 重新連線確認同網段

```bash
# Pi Zero 重連 ASUS_DC
sudo nmcli connection delete "ASUS_DC"
sudo nmcli device wifi connect "ASUS_DC" password "密碼"

# 確認 IP
ip route
# → default via 192.168.0.1 ... src 192.168.0.155 ✓ 同網段！

# 桌機 ping Pi Zero
ping 192.168.0.155
# → 回覆: 5~37ms, 0% 遺失 ✓
```

### 6. WoL 首次成功

```bash
wakeonlan -i 192.168.0.255 50:EB:F6:5C:CE:3E
# → 桌機開機 ✓
```

### 7. WoL 廣播 vs 單播的坑

```bash
# ✗ 用桌機 IP → 關機後 IP 沒人持有，封包送不到
wakeonlan -i 192.168.0.211 50:EB:F6:5C:CE:3E   # 無反應

# ✓ 用廣播位址 → 整個網段都收到，網卡 MAC 比對後喚醒
wakeonlan -i 192.168.0.255 50:EB:F6:5C:CE:3E   # 成功 ✓
```

**原理：** WoL 魔術封包是送給 MAC 位址的，不是送給 IP。用廣播位址 `192.168.0.255` 讓整個網段的設備都收到封包，網卡發現封包內的 MAC 跟自己匹配就觸發開機。桌機關機後 `192.168.0.211` 已無人持有，單播送不達。

---

## 網路拓撲（最終架構）

```
牆壁網路口 → CBN modem (192.168.0.x, DHCP)
 └── AX1800HP（只負責 DHCP/NAT）
     └── LAN → DGS-108（8 port 無管理 Switch）
               ├── port → 桌機: 192.168.0.211
               └── port → ASUS N12+（AP 模式，無 NAT）
                           └── WiFi (ASUS_DC) → Pi Zero: 192.168.0.155
```

所有設備同在 `192.168.0.x` 網段，WoL 廣播封包可達。DGS-108 將內網交換從 AX1800HP 分離，即使 AX1800HP 韌體抽風，桌機與 Pi Zero 仍保持 L2 互通，WoL 不受影響。

---

## 桌機 WoL 相關設定確認

### BIOS（ASUS Z690 TUF）

| 項目 | 設定值 |
|------|--------|
| ErP 支援 | Disabled |
| 由 PCI-E 裝置喚醒 | Enabled |
| Max Power Saving | Disabled |

### Windows（Intel I225-V 網卡）

- 電源管理：允許電腦關閉這個裝置以節省電源
- 電源管理：允許這個裝置喚醒電腦
- 電源管理：只允許 Magic 封包喚醒電腦
- 進階 → 收到 Magic 封包時喚醒：啟用
- 電源選項 → 快速啟動：**已關閉**

---

## Moonlight 串流調校

| 項目 | 設定值 | 備註 |
|------|--------|------|
| 解析度 | 2560×1440 | Mac M5 15 吋螢幕原生適合 |
| 幀率 | 60fps | |
| 碼率 | 55 Mbps | 75Mbps 反而增加 NVENC 編碼延遲 |
| 編碼端 | RTX 3060 Ti NVENC | 桌機硬體編碼 |
| 解碼端 | M5 VideoToolbox / Media Engine | Mac 硬體解碼，功耗極低（CPU+GPU < 1W） |
| Tailscale 連線 | direct（非 relay） | 延遲最低 |

**發現：** 碼率過高（75Mbps+）反而增加延遲，降到 55Mbps 後延遲感明顯改善。Mac M5 解碼 1440p 串流整機功耗僅約 6W，Media Engine 硬體解碼效率極高，CPU/GPU 幾乎不參與。

---

## 安裝清單（Pi Zero / Tomori）

- [x] 系統更新（`apt full-upgrade`）
- [x] Tailscale
- [x] etherwake / wakeonlan
- [x] log2ram

---

## 學到的教訓

1. **NetworkManager vs wpa_supplicant：** 新版 Raspbian 用 NM，`raspi-config` 改 WiFi 可能無效，用 `nmcli`。
2. **雙 NAT 是 WoL 的天敵：** WoL 靠 Layer 2 廣播，過不了 NAT。第二台路由器應改 AP 模式。
3. **ErP Ready 必須 Disabled：** 否則關機後主機板切斷網卡供電，WoL 不可能成功。
4. **Windows 快速啟動要關：** 快速啟動會影響 WoL 行為。
5. **etherwake vs wakeonlan：** WiFi 環境下 `wakeonlan`（UDP Layer 3 廣播）比 `etherwake`（Layer 2）更可靠。
6. **WoL 必須用廣播位址：** 關機後桌機沒有 IP，用 `192.168.0.255`（廣播）而非桌機 IP `192.168.0.211`（單播），才能讓封包送達。
7. **碼率不是越高越好：** Moonlight 串流碼率過高反而增加編碼延遲，1440p/60fps 用 55Mbps 即可。
8. **Apple Media Engine 效率驚人：** M5 解碼 1440p 串流幾乎不耗電，整機功耗跟瀏覽網頁差不多。
