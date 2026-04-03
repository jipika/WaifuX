import zh from './zh.json';
import en from './en.json';
import ja from './ja.json';

export type Language = 'zh' | 'en' | 'ja';

export const translations = {
  zh,
  en,
  ja
};

export type Translations = typeof zh;
