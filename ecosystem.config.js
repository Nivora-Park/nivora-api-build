module.exports = {
  apps: Array.from({ length: 1 }, (_, i) => ({
    name: `nivora-api-${8080 + i}`,
    script: './build/nivora-api',
    exec_mode: 'fork',
    instances: 1,
    autorestart: true,
    watch: false,
    env: {
        DEBUG: 'False',
        ALLOWED_HOSTS: '0.0.0.0',
        SERVER_HOST: '0.0.0.0',
        SERVER_PORT: `${8080 + i}`,
        SERVER_TIMEZONE: 'Asia/Jakarta',
        DB_LOG_MODE: 'True',
        MASTER_DB_NAME: 'nivora',
        MASTER_DB_USER: 'postgres',
        MASTER_DB_PASSWORD: 'postgres',
        MASTER_DB_HOST: 'localhost',
        MASTER_DB_PORT: 5432,
        MASTER_DB_SSL_MODE: 'disable',
        REPLICA_DB_NAME: 'nivora',
        REPLICA_DB_USER: 'postgres',
        REPLICA_DB_PASSWORD: 'postgres',
        REPLICA_DB_HOST: 'localhost',
        REPLICA_DB_PORT: 5432,
        REPLICA_DB_SSL_MODE: 'disable',
        SECRET: 'h9wt*pasj6796j##w(w8=xaje8tpi6h*r&hzgrz065u&ed+k2)',
        AUTH_EXPIRES_IN: '24h0m0s'
    }
  }))
};