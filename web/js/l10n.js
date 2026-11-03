// 界面与提示文字只有中文和英文两种：浏览器首选语言是中文就用中文，否则用英文。
// 网址带 ?lang=zh / ?lang=en 时按网址来（两种语言各有固定网址，搜索引擎才能分别收录；
// 抓取页面的爬虫浏览器语言一般是英文，不加的话只会收录英文版）。

const param = typeof location !== 'undefined' ? new URLSearchParams(location.search).get('lang') : null;

/** 网址里指定的语言：'zh' / 'en'，没指定或写错是 null */
export const langParam = param === 'zh' || param === 'en' ? param : null;

const lang = langParam || (typeof navigator !== 'undefined' && (navigator.languages?.[0] || navigator.language)) || '';

export const isChinese = lang.toLowerCase().startsWith('zh');

/** `L("中文", "English")` */
export const L = (zh, en) => (isChinese ? zh : en);
