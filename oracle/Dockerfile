FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY index.js chain.js scoring.js epoch-policy.js http-helpers.js store.js external.js ./

CMD ["node", "index.js"]
