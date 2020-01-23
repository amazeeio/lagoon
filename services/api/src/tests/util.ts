import { sign } from 'jsonwebtoken';
import { promisify } from 'util';

const exec = promisify(require('child_process').exec);
const { JWTSECRET, JWTAUDIENCE } = process.env;

type LegacyToken = string;

/**
 * Fetches legacy JWT admin token from auto-idler container.
 */
const getLegacyAdminToken = async (): Promise<LegacyToken> => {
  try {
    const { stdout: jwtToken, stderr }: { stdout: LegacyToken, stderr: any } = await exec(
      'docker-compose exec -T auto-idler /create_jwt.sh',
    );
    if (stderr) {
      throw stderr;
    }
    return jwtToken;
  } catch (err) {
    console.error(err);
  }
};

/**
 * Generates legacy JWT admin token from environment variables.
 */
const generateLegacyAdminToken = (): LegacyToken => {
  const payload = {
    role: 'admin',
    iss: 'api',
    aud: JWTAUDIENCE,
    sub: 'api',
  };

  return sign(payload, JWTSECRET);
}

/**
 * If running tests locally, get a token from auto-idler, otherwise generate
 * it inline.
 */
export const legacyAdminToken = async (): Promise<LegacyToken> => {
  if (JWTSECRET) {
    return generateLegacyAdminToken();
  } else {
    return getLegacyAdminToken();
  }
}