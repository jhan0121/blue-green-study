-- Safe migration: Add email column with NULL default
-- This is backward compatible with v1.0

ALTER TABLE User
ADD COLUMN email VARCHAR(255) DEFAULT NULL
COMMENT 'User email address - added in v2.0';

-- Create index for future queries
CREATE INDEX idx_user_email ON User(email);
