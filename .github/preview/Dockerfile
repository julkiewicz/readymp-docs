# The image a docs preview runs: nginx serving the built site, nothing else.
#
# Built by the deploy job in .github/workflows/preview.yml from the default branch's copy of this file, never the
# pull request's, with the workspace as the build context. The only thing from the pull request that reaches it is
# `site/`, the built output the build job handed over, which is copied in as files and never run.
#
# Unprivileged, so nginx runs as a non-root user and listens on 8080.
FROM nginxinc/nginx-unprivileged:1.27.5-alpine

COPY .ci/.github/preview/nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /usr/share/nginx/html/

EXPOSE 8080
