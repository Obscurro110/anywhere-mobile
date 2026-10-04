# ---- Anywhere Relay Server ----
# 多阶段构建：保持镜像精简，并以非 root 用户运行（降低被攻破后的影响面）
FROM node:20-alpine AS base
WORKDIR /app
ENV NODE_ENV=production

# 只拷贝清单，先装依赖以利用构建缓存
# 用 npm ci：有 package-lock.json，保证可复现、且比 npm install 更快更稳
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

# 拷贝源码
COPY src ./src

# 数据卷：用于暂存中转文件。先建好目录并交给 node 用户
RUN mkdir -p /app/data/files && chown -R node:node /app/data

# 默认端口（可用 -e PORT 覆盖）
ENV PORT=8787
ENV HOST=0.0.0.0
ENV FILE_DIR=/app/data/files

EXPOSE 8787

# ⚠️ 降权：以 node 用户（uid 1000）运行，而不是 root。
# 若服务器被 RCE，攻击者不再是 root，逃逸/横向扩散难度大增。
USER node

# 健康检查（1Panel / Docker 均可读取）
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/index.js"]
