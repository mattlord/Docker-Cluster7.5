FROM oraclelinux:latest

ENV SERVER_PACKAGE_URL http://dev.mysql.com/get/Downloads/MySQL-Cluster-7.5/MySQL-Cluster-server-gpl-7.5.2-1.el7.x86_64.rpm
ENV CLIENT_PACKAGE_URL http://dev.mysql.com/get/Downloads/MySQL-Cluster-7.5/MySQL-Cluster-client-gpl-7.5.2-1.el7.x86_64.rpm
ENV LIB_PACKAGE_URL http://dev.mysql.com/get/Downloads/MySQL-Cluster-7.5/MySQL-Cluster-shared-gpl-7.5.2-1.el7.x86_64.rpm

# Install server
RUN yum install -y $SERVER_PACKAGE_URL $CLIENT_PACKAGE_URL $LIB_PACKAGE_URL
RUN rm -rf /var/cache/yum/*
RUN mkdir /docker-entrypoint-initdb.d

ADD my.cnf /etc/mysql/my.cnf
ADD cluster-config.ini /etc/mysql/cluster-config.ini

VOLUME /var/lib/mysql-cluster

COPY mysql_cluster-entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 3306 33060 1186 
CMD [""]

