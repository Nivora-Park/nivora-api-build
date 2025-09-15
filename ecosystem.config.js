module.exports = {
  apps: Array.from({ length: 1 }, (_, i) => ({
    name: `nivora-api-${8080 + i}`,
    script: './build/nivora-api',
    exec_mode: 'fork',
    instances: 1,
    autorestart: true,
    watch: false
  }))
};