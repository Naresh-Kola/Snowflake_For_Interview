-- ============================================
-- Step 4: Assign Public Key to Connector User
-- ============================================
-- Links the RSA public key to KAFKA_CONNECTOR_USER.
-- The connector will authenticate using the matching private key.

ALTER USER KAFKA_CONNECTOR_USER SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAskIx1mKEfCO43t2UcBdYfC+lwi675qxMpF41LVcQh/iPBi49Cgs9Jw8em9NOsizV7hTgkcLJzTA48yIkGW6lzBAvs/IIcDJQ3YKbf74/Xsr6+k4VXVgF1L6PIzGcK4ZLLsTiA2xrhSuUW4nM0WglLPp04Sga3hT+c859PiBvsz9tFqWN0iI+WJEdJbJzVj8aYQUpns9tbmyA9YNYRUniSy30DscizLKyBvcKh/IcfFXMGHj6peKUYNT3dqTiKwdf3yfUmnybDtBlTzr0I0qeFQahR3uhseoHh9rZucq8usHb2LXsYDzyeigjbfQ53Sev8zfMI9IH4zyPY6cV1vRRpwIDAQAB';

-- Verify
DESCRIBE USER KAFKA_CONNECTOR_USER;
