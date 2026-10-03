# ---- Anywhere Relay Server ----
# 多阶段构建：保持镜像精简
FROM node:20-alpine AS base
WORKDIR /app
ENV NODE_ENV=production

# 只拷贝清单，先装依赖以利用构建缓存
COPY package.json ./
# 若存在 lock 文件也可一并拷贝（本仓库 server 无 lock 文件，故用通配容错）
COPY package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund

# 拷贝源码
COPY src ./src

# 数据卷：用于暂存中转文件
RUN mkdir -p /app/data/files
VOLUME ["/app/data"]

# 默认端口（可用 -e PORT 覆盖）
ENV PORT=8787
ENV HOST=0.0.0.0
ENV FILE_DIR=/app/data/files

EXPOSE 8787

# 健康检查（1Panel / Docker 均可读取）
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/index.js"]
