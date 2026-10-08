# 未签名 HAP 的自签与安装

GitHub Release 中的 `LIAN-CONNECT-v0.03-unsigned.hap` 是 arm64 未签名包，不能直接
安装。你需要使用自己的 HarmonyOS 应用证书和 Profile 完成签名；Profile 必须匹配
包名 `com.lianconnect.app`，并包含目标调试设备，或具备相应的发布安装资格。

## 推荐方式：DevEco Studio

1. 在 AppGallery Connect/DevEco Studio 中为包名 `com.lianconnect.app` 创建或选择
   自己的签名证书和 Profile。
2. 在 DevEco Studio 的签名配置中导入证书、私钥库和 Profile。
3. 从本仓库源码构建签名 HAP。这是最不容易遗漏包名、设备和权限配置的方式。

签名材料只应保存在你自己的受控环境中。不要把 `.p12`、`.p7b`、`.cer`、密码或
本机 `build-profile.json5` 提交到仓库。

## 命令行签名已有 HAP

DevEco Studio 自带 `hap-sign-tool.jar`。下列命令以 macOS 默认安装路径为例，密码
采用交互输入，不写入 shell 历史：

```bash
HAP_SIGN_TOOL='/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar'

java -jar "$HAP_SIGN_TOOL" sign-app \
  -mode localSign \
  -keyAlias YOUR_KEY_ALIAS \
  -appCertFile /path/to/your-app-cert.cer \
  -profileFile /path/to/your-profile.p7b \
  -inFile LIAN-CONNECT-v0.03-unsigned.hap \
  -signAlg SHA256withECDSA \
  -keystoreFile /path/to/your-keystore.p12 \
  -outFile LIAN-CONNECT-v0.03-signed.hap \
  -compatibleVersion 22 \
  -signCode 1 \
  -pwdInputMode 1
```

不同 DevEco/SDK 版本的参数可能不同，可先运行：

```bash
java -jar "$HAP_SIGN_TOOL" sign-app -h
```

## 校验与安装

先校验下载文件：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

然后通过 DevEco Studio 安装签名后的 HAP，或使用与本机 SDK 配套的 `hdc`：

```bash
hdc install LIAN-CONNECT-v0.03-signed.hap
```

若出现签名、Profile 或设备不匹配错误，请检查包名、证书链、Profile 有效期和目标
设备 UDID。不要尝试安装未签名包，也不要使用他人的私钥或 Profile。
