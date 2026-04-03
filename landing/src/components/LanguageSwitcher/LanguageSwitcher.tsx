import { useLanguage } from '../../contexts/LanguageContext';
import type { Language } from '../../i18n';
import { Globe } from 'lucide-react';
import './LanguageSwitcher.css';

const languages: { code: Language; label: string; flag: string }[] = [
  { code: 'zh', label: '中文', flag: '🇨🇳' },
  { code: 'en', label: 'EN', flag: '🇺🇸' },
  { code: 'ja', label: '日本語', flag: '🇯🇵' },
];

export function LanguageSwitcher() {
  const { language, setLanguage, t } = useLanguage();

  return (
    <div className="language-switcher">
      <Globe className="language-icon" size={14} />
      <div className="language-buttons">
        {languages.map((lang) => (
          <button
            key={lang.code}
            onClick={() => setLanguage(lang.code)}
            className={`language-btn ${language === lang.code ? 'active' : ''}`}
            title={t.language[lang.code]}
          >
            <span className="language-flag">{lang.flag}</span>
            <span className="language-label">{lang.label}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
