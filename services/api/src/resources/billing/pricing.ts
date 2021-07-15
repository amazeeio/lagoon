// Naming conventions base off - https://airbnb.io/javascript/#naming--uppercase

export const HIT_TIERS = [
  { min: 0, max: 300_000 },
  { min: 300_001, max: 2_500_000 },
  { min: 2_500_001, max: 10_000_000 },
  { min: 10_000_001, max: 99_999_999_999 },
];

export const CURRENCIES = {
  USD: 'USD',
  CHF: 'CHF',
  EUR: 'EUR',
  GBP: 'GBP',
  ZAR: 'ZAR',
  AUD: 'AUD',
};

export const AVAILABILITY = {
  STANDARD: 'STANDARD',
  HIGH: 'HIGH',
  POLYSITE: 'POLYSITE'
};

export const USD = {
  storagePerDay: 0.0333,
  availability: {
    STANDARD: {
      hitCosts: [0.0, 0.00015, 0.00007, 0.00003],
      hitBase: 69.0,
      prodSitePerHour: 0.0417,
      devSitePerHour: 0.0139,
    },
    HIGH: {
      hitCosts: [0.0, 0.0003, 0.00014, 0.00006],
      hitBase: 200.0,
      prodSitePerHour: 0.1389,
      devSitePerHour: 0.0417,
    },
  },
};

export const CHF = {
  storagePerDay: 0.0333,
  availability: {
    STANDARD: {
      hitCosts: [0.0, 0.00015, 0.00007, 0.00003],
      hitBase: 69.0,
      prodSitePerHour: 0.0417,
      devSitePerHour: 0.0139,
    },
    HIGH: {
      hitCosts: [0.0, 0.0003, 0.00014, 0.00006],
      hitBase: 200.0,
      prodSitePerHour: 0.1389,
      devSitePerHour: 0.0417,
    },
  },
};

export const EUR = {
  storagePerDay: 0.0333,
  availability: {
    STANDARD: {
      hitCosts: [0.0, 0.00015, 0.00007, 0.00003],
      hitBase: 69.0,
      prodSitePerHour: 0.0417,
      devSitePerHour: 0.0139,
    },
    HIGH: {
      hitCosts: [0.0, 0.0003, 0.00014, 0.00006],
      hitBase: 200.0,
      prodSitePerHour: 0.1389,
      devSitePerHour: 0.0417,
    },
  },
};

export const GBP = {
  storagePerDay: 0.02833,
  availability: {
    STANDARD: {
      hitCosts: [0.0, 0.00012, 0.000056, 0.000024],
      hitBase: 55.0,
      prodSitePerHour: 0.0347,
      devSitePerHour: 0.0116,
    },
    HIGH: {
      hitCosts: [0.0, 0.00024, 0.000112, 0.000048],
      hitBase: 200.0,
      prodSitePerHour: 0.1111,
      devSitePerHour: 0.0347,
    },
  },
};

export const ZAR = {
  storagePerDay: 0.0333,
  availability: {
    STANDARD: {
      hitCosts: [0, 0.0015, 0.0007, 0.0003],
      hitBase: 280,
      prodSitePerHour: undefined,
      devSitePerHour: undefined,
    },
  },
};

export const AUD = {
  storagePerDay: 0.06,
  availability: {
    STANDARD: {
      hitCosts: [0.0, 0.00027, 0.00018, 0.00012],
      hitBase: 125.0,
      prodSitePerHour: 0.075,
      devSitePerHour: 0.025,
    },
    HIGH: {
      hitCosts: [0.0, 0.00054, 0.00036, 0.00024],
      hitBase: 360.0,
      prodSitePerHour: 0.25,
      devSitePerHour: 0.075,
    },
  },
};

export const CURRENCY_PRICING = {
  USD,
  CHF,
  EUR,
  GBP,
  ZAR,
  AUD,
};

export default {
  HIT_TIERS,
  CURRENCIES,
  AVAILABILITY,
  CURRENCY_PRICING,
};
