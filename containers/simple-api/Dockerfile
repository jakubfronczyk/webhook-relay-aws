FROM nginx:alpine

# Copy custom HTML page
COPY index.html /usr/share/nginx/html/

# Add health check endpoint configuration
RUN echo 'server { \
    listen 80; \
    location /health { \
        access_log off; \
        return 200 "healthy\n"; \
        add_header Content-Type text/plain; \
    } \
    location / { \
        try_files $uri $uri/ /index.html; \
    } \
}' > /etc/nginx/conf.d/default.conf

EXPOSE 80

# Health check for container
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1
