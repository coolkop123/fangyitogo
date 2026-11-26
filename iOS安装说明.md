# 随身同传 iPhone 原生版：用 Windows 电脑安装

不需要 Mac。GitHub 的云端 Mac 会自动编译好安装包（IPA），你在 Windows 上用免费工具 Sideloadly，加上自己的 Apple ID，把它装到 iPhone 上。

## 需要准备

- Windows 10 或 11 电脑，一根 iPhone 数据线
- iPhone 系统 iOS 18 或更新
- 一个 Apple ID（就是你平时登录 iPhone 的那个，也可以另外注册一个）
- GitHub 账号（下载安装包时需要登录）

## 第 1 步：下载安装包

1. 电脑浏览器打开：https://github.com/coolkop123/fangyitogo/actions/workflows/ios.yml
2. 点最上面一条绿色 ✓ 的记录。
3. 拉到页面最下面的 **Artifacts**，点 **SuiShenTongChuan-ipa** 下载。
4. 下载的是一个 zip，解压后得到 **SuiShenTongChuan.ipa**。

每次我更新原生版的代码，这里都会自动生成新的安装包，下载最新的那条就行。

## 第 2 步：在电脑上安装 iTunes、iCloud 和 Sideloadly

1. **iTunes 和 iCloud 必须用苹果官网的版本**，不能用微软商店里的。如果装过微软商店版，先卸载。
   - iTunes：https://www.apple.com/itunes/download/win64
   - iCloud：在 sideloadly.io 页面上有官网下载链接
2. 打开 https://sideloadly.io ，下载 Windows 版 Sideloadly 并安装。

## 第 3 步：iPhone 上的准备

1. 用数据线把 iPhone 连上电脑，iPhone 上弹出「要信任此电脑吗」时点 **信任**。
2. 打开 iPhone 的 **设置 › 隐私与安全性 › 开发者模式**，打开开关，按提示重启 iPhone。
   （如果看不到「开发者模式」，先完成第 4 步装一次，它就会出现。）

## 第 4 步：用 Sideloadly 安装

1. 打开 Sideloadly，上方会显示你的 iPhone。
2. 在 **Apple account** 一栏填你的 Apple ID 邮箱。
3. 把 **SuiShenTongChuan.ipa** 拖到 Sideloadly 左上角的 IPA 图标上。
4. 点 **Start**，按提示输入 Apple ID 密码（如果开了双重认证，还要输入验证码）。
5. 等待显示 **Done**。

## 第 5 步：信任并打开

1. iPhone 打开 **设置 › 通用 › VPN 与设备管理**，点你的 Apple ID，点 **信任**。
2. 回到桌面，打开「随身同传」。
3. 第一次使用时，允许麦克风和语音识别权限。
4. 第一次翻译某一组语言时，系统会提示下载离线翻译包，点下载。

## 需要知道的限制

- 用免费 Apple ID 安装，**每 7 天要重新安装一次**：连上电脑，在 Sideloadly 里再点一次 Start 即可，数据不会丢。付费的苹果开发者账号（每年 99 美元）可以一年签一次。
- 免费 Apple ID 最多同时装 3 个这类 App。
- 想正式发给别人用或上架 App Store，需要付费的苹果开发者账号。

## 同传怎么用

1. 连好蓝牙耳机（或者用手机外放）。
2. 切到「同传收听」，点「开始同传」。
3. 中文和英文随便说。屏幕上会同时实时显示「中文 / English」两行正在识别的文字。每句说完稍微停顿，App 会自动判断是谁说的，翻译并播报。
4. 点同传字幕卡片右上角的「全屏」，可以大字显示，给大家一起看。
