# bwlimit

用 `tc` 把 Linux VPS 的带宽限制为固定值(入口 / 出口)。需要 root 和 `iproute2`。

把下面的 `restaurant8/bwlimit` 换成你的仓库。

## 一键安装(入口限 5Mbps,开机自动生效)

```bash
curl -fsSL https://raw.githubusercontent.com/restaurant8/bwlimit/main/bwlimit.sh -o /usr/local/sbin/bwlimit && chmod +x /usr/local/sbin/bwlimit && bwlimit install -d 5
```

## 只临时生效(重启后失效,不安装)

```bash
curl -fsSL https://raw.githubusercontent.com/restaurant8/bwlimit/main/bwlimit.sh | bash -s -- start -d 5
```

## 其他命令

```bash
bwlimit install -d 5 -u 5     # 入口出口都限 5Mbps
bwlimit install -d 500kbit    # 也可以写 kbit / mbit
bwlimit start -d 10 -i eth0   # 指定网卡, 立即生效
bwlimit status                # 查看规则和流量统计
bwlimit stop                  # 临时取消限速
bwlimit uninstall             # 取消限速并移除服务
```

`-d` 入口(下载),`-u` 出口(上传),纯数字单位为 Mbps。
