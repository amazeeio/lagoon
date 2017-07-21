import winston from 'winston';
import path from 'path';
import fs from 'fs';

// Create the logs directory if it doesn't exist yet.
const directory = path.join('.', 'logs');
if (!fs.existsSync(directory)) {
  fs.mkdirSync(directory);
}

const logger = new winston.Logger({
  exitOnError: false,
  transports: [
    new winston.transports.File({
      level: 'info',
      filename: path.join(directory, 'info.log'),
      name: 'info-file',
    }),
    new winston.transports.File({
      level: 'error',
      filename: path.join(directory, 'error.log'),
      name: 'error-file',
    }),
    new winston.transports.Console({
      level: 'debug',
      handleExceptions: true,
      json: false,
      colorize: true,
    }),
  ],
});

if (typeof global.debug === 'undefined') {
  global.debug = (message) => {
    if (process.env.NODE_ENV === 'development') {
      logger.debug(message);
    }
  };
}

export default logger;
