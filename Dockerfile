# Dockerfile — baseline Rocky Linux 8.10, simulando a máquina-alvo (Issabel PBX) dos clientes.
FROM rockylinux/rockylinux:8.10

# rockylinux:8.10 é bem mais enxuta que uma instalação real de Issabel (que já vem com
# findutils/git/tar/curl padrão) — instala aqui o que o pvx-core precisa em runtime
# (findutils pro smoke.sh, git pro `pvx modules install <url-git>`), pra não mascarar
# nenhuma outra lacuna real de dependência atrás de "a imagem de teste não tinha isso".
RUN dnf install -y findutils git procps-ng sudo
#RUN dnf upgrade -y
RUN dnf clean all


COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/sbin/init"]
