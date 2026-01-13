# 极简 Xray Reality Vision 一键安装脚本

安装完成会提供 `vless://` 链接与二维码，支持宾客用户。  
通过安装Caddy来提供证书，并减少回落延时等潜在特征。自用脚本，为方便维护，使用固定版本的Xray。    
本脚本的使用场景为小范围的朋友间共享一台服务器日常使用。代理流量经原样传输，不含任何网站封锁列表。

|支持的系统|版本|
|:----:|:----:|
|Debian|  10 11 12 13  | 
|Ubuntu|  18 20 22 24  |
|Rocky| 8 9 10   |
|AlmaLinux|  8 9 10    |
 
需要以root用户运行。  
独特的重装脚本设计可以方便在重装系统后快速恢复服务。

## 首次安装
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bluebluesoda/reality-simple/refs/heads/main/install.sh)
``` 

### 或自定义安装
```bash
SEED=rand0mString SNI=www.example.com PORT=8443 HOST=ddns.yourdomain SOCKS5=user:pass@ip:port bash <(curl -fsSL https://raw.githubusercontent.com/bluebluesoda/reality-simple/refs/heads/main/install.sh)
```

### 或多用户安装
```bash
# 例子：创建主用户 和 3 个宾客账号
bash <(curl -fsSL https://raw.githubusercontent.com/bluebluesoda/reality-simple/refs/heads/main/install.sh) user1 user2 user3
```
**注：每个user必须是不重复的字符串**   
如果你是想在原先的配置上增加用户，请使用已导出的重装指令+拼接新的字符串的方式重新安装。删除用户同理。

### Caddy 行为
脚本自动安装和配置Caddy，用于证书管理。Caddy默认配置为对任何请求返回状态码 404 的空响应。   
若将`@keep-caddyfile` 放在第一个用户的位置，则安装过程将完全跳过操作Caddy。 

## 使用指南

### 查看连接信息
```bash
cat _xray_url_
```
包含二维码、连接链接和完整重装命令。

### 查看流量统计
```bash
xray api statsquery --server=127.0.0.1:10085
```
简易的多用户安装不支持限制用户使用量，可通过上述命令查询Xray启动至今所有用户流量使用情况（单位为字节）

# 实验性工具：反向穿透使用家宽落地
场景：服务器1台作为入口，树莓派等常在线设备作为出口。最终通过出口设备使用海外朋友的家宽网络。   
常在线设备将反向连接到服务器，因此可在NAT或防火墙后无需公网IP。   
**请注意：反向连接被设计为使用裸Vless，无加密。** 以减少在一些IoT设备上的性能瓶颈。    

**在云服务器上安装** 功能与标准脚本相同
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bluebluesoda/reality-simple/refs/heads/main/rhop-cloud.sh)
``` 
**安装后将脚本输出的命令放到落地设备上运行** 也可以参考脚本中的配置文件手动添加到设备上运行。
