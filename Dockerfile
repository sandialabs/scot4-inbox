# Start with debian:bookworm image with scot4 perl installed
FROM ghcr.io/sandialabs/scot4-perl-builder@sha256:6a92390d96baf3c1ad73fcdf9af5047a36e880c5ce026c91cff98d0064e2e67f

# Create necessary directories 
RUN mkdir -p /opt/scot4-inbox && mkdir -p /var/log/scot

# Copy over required files
COPY . /opt/scot4-inbox

# create user/group for scotinbox
RUN groupadd scotinbox && \
    useradd -c "Scot Inbox User" -g "scotinbox" -d /opt/scot4-inbox -M -s /bin/bash scotinbox && \
    chown -R scotinbox:scotinbox /opt/scot4-inbox && \
    chown -R scotinbox:scotinbox /var/log/scot
    
# start container as scotinbox user
USER scotinbox

# airflow will handle start, but if not
ENTRYPOINT ["/opt/scot4-inbox/bin/inbox.pl"]
CMD ["-?"]
