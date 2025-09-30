CREATE TABLE User (
    id bigint NOT NULL auto_increment,
    name varchar(255) NOT NULL DEFAULT 'User',
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
