/**
 * WaifuX 漫画源模板
 * 基于 Venera 规则格式
 * 
 * 使用方法：
 * 1. 复制此文件并重命名为你的漫画源名称，如: copy_manga.js
 * 2. 修改类名和配置信息
 * 3. 实现各个功能方法
 * 4. 在 App 中导入测试
 */

class ComicSourceTemplate extends ComicSource {
    // ==================== 基本信息 ====================
    
    // 漫画源显示名称
    name = "模板漫画源"
    
    // 唯一标识符（只能包含字母、数字、下划线）
    key = "template_source"
    
    // 规则版本，使用语义化版本号
    version = "1.0.0"
    
    // 最低 App 版本要求
    minAppVersion = "1.0.0"
    
    // 规则更新地址（可选）
    url = ""
    
    // ==================== 初始化（可选） ====================
    
    /**
     * 初始化函数，在源被加载时调用
     * 可以在这里进行一些初始化设置
     */
    init() {
        console.log(`[${this.name}] 初始化完成`)
    }
    
    // ==================== 账号系统（可选） ====================
    
    /**
     * 账号相关配置
     * 如果你的漫画源需要登录，请配置此项
     * 如果不需要，可以删除整个 account 对象
     */
    account = {
        /**
         * 账号密码登录
         * @param account {string} 账号
         * @param pwd {string} 密码
         * @returns {Promise<string>} 返回任意值表示成功
         */
        login: async (account, pwd) => {
            // 示例：发送登录请求
            let res = await Network.post('https://example.com/api/login', {
                'content-type': 'application/x-www-form-urlencoded'
            }, `account=${encodeURIComponent(account)}&password=${encodeURIComponent(pwd)}`)
            
            if (res.status === 200) {
                let json = JSON.parse(res.body)
                if (json.token) {
                    // 保存 token
                    this.saveData('token', json.token)
                    return 'ok'
                }
            }
            
            throw '登录失败，请检查账号密码'
        },
        
        /**
         * WebView 登录配置
         * 如果网站需要验证码或复杂登录流程，使用此方式
         */
        loginWithWebview: {
            // 登录页面 URL
            url: "https://example.com/login",
            
            /**
             * 检查登录状态
             * @param url {string} 当前页面 URL
             * @param title {string} 当前页面标题
             * @returns {boolean} 返回 true 表示登录成功
             */
            checkStatus: (url, title) => {
                // 示例：URL 包含 /home 表示登录成功
                return url.includes('/home') || url.includes('/dashboard')
            },
            
            /**
             * 登录成功回调（可选）
             */
            onLoginSuccess: () => {
                console.log('WebView 登录成功')
            }
        },
        
        /**
         * Cookie 登录配置
         * 适用于只需要 Cookie 就能访问的网站
         */
        loginWithCookies: {
            // 需要的 cookie 字段
            fields: ["session_id", "user_token"],
            
            /**
             * 验证 cookie 有效性
             * @param values {string[]} cookie 值数组，顺序与 fields 一致
             * @returns {Promise<boolean>}
             */
            validate: async (values) => {
                // 设置 cookie
                Network.setCookies('https://example.com', [
                    new Cookie({ name: 'session_id', value: values[0], domain: 'example.com' }),
                    new Cookie({ name: 'user_token', value: values[1], domain: 'example.com' })
                ])
                
                // 验证 cookie 是否有效
                let res = await Network.get('https://example.com/api/user/profile')
                return res.status === 200
            }
        },
        
        /**
         * 登出
         * 清除登录相关数据
         */
        logout: () => {
            // 删除保存的 token
            this.deleteData('token')
            
            // 清除 cookie
            Network.deleteCookies('https://example.com')
            
            console.log('已登出')
        },
        
        // 注册页面 URL（可选）
        registerWebsite: "https://example.com/register"
    }
    
    // ==================== 探索页面 ====================
    
    /**
     * 探索页面配置
     * 用于 App 首页展示推荐内容
     */
    explore = [
        {
            // 页面标题
            title: "首页",
            
            // 页面类型：multiPartPage / multiPageComicList / mixed
            // - multiPartPage: 多区块页面，每个区块有标题和漫画列表
            // - multiPageComicList: 纯漫画列表，分页加载
            // - mixed: 混合模式
            type: "multiPartPage",
            
            /**
             * 加载页面数据
             * @param page {number|null} 页码，multiPartPage 为 null
             * @returns {Promise<Object>}
             */
            load: async (page) => {
                // 示例：同时加载多个区块的数据
                let [hotRes, latestRes] = await Promise.all([
                    Network.get('https://example.com/api/comics/hot?limit=10'),
                    Network.get('https://example.com/api/comics/latest?limit=10')
                ])
                
                let hotData = JSON.parse(hotRes.body)
                let latestData = JSON.parse(latestRes.body)
                
                // 解析漫画数据
                let parseComic = (item) => new Comic({
                    id: item.id,
                    title: item.title,
                    subTitle: item.author || item.artist || "",
                    cover: item.cover,
                    tags: item.tags || [],
                    description: item.summary || "",
                    maxPage: item.chapter_count || null
                })
                
                // 返回区块数据
                return {
                    "热门推荐": {
                        title: "热门推荐",
                        comics: hotData.data?.map(parseComic) || [],
                        viewMore: {
                            page: "category",
                            attributes: { category: "hot" }
                        }
                    },
                    "最新更新": {
                        title: "最新更新",
                        comics: latestData.data?.map(parseComic) || [],
                        viewMore: {
                            page: "category", 
                            attributes: { category: "latest" }
                        }
                    }
                }
            }
        },
        {
            title: "排行榜",
            type: "multiPageComicList",
            
            /**
             * 加载排行榜数据
             * @param page {number} 页码，从 1 开始
             * @returns {Promise<{comics: Comic[], maxPage: number}>}
             */
            load: async (page) => {
                let res = await Network.get(`https://example.com/api/ranking?page=${page}&limit=20`)
                let data = JSON.parse(res.body)
                
                return {
                    comics: data.list?.map(item => new Comic({
                        id: item.id,
                        title: item.title,
                        subTitle: item.author,
                        cover: item.cover,
                        stars: item.rating ? item.rating / 2 : null  // 转换为 5 星制
                    })) || [],
                    maxPage: Math.ceil(data.total / 20)
                }
            }
        }
    ]
    
    // ==================== 分类页面 ====================
    
    /**
     * 分类页面配置
     */
    category = {
        // 页面标题
        title: "分类",
        
        // 分类区块
        parts: [
            {
                name: "题材",  // 区块标题
                type: "fixed",  // fixed / random / dynamic
                
                // 分类列表
                categories: [
                    { 
                        label: "全部", 
                        target: { page: "category", attributes: { category: "all" } }
                    },
                    { 
                        label: "冒险", 
                        target: { page: "category", attributes: { category: "adventure" } }
                    },
                    { 
                        label: "奇幻", 
                        target: { page: "category", attributes: { category: "fantasy" } }
                    },
                    { 
                        label: "恋爱", 
                        target: { page: "category", attributes: { category: "romance" } }
                    },
                    { 
                        label: "搞笑", 
                        target: { page: "category", attributes: { category: "comedy" } }
                    }
                ]
            },
            {
                name: "地区",
                type: "fixed",
                categories: [
                    { label: "日本", target: { page: "category", attributes: { region: "jp" } } },
                    { label: "韩国", target: { page: "category", attributes: { region: "kr" } } },
                    { label: "国产", target: { page: "category", attributes: { region: "cn" } } },
                    { label: "欧美", target: { page: "category", attributes: { region: "en" } } }
                ]
            },
            {
                name: "进度",
                type: "fixed",
                categories: [
                    { label: "连载中", target: { page: "category", attributes: { status: "ongoing" } } },
                    { label: "已完结", target: { page: "category", attributes: { status: "completed" } } }
                ]
            }
        ],
        
        // 是否启用排行榜页面
        enableRankingPage: true
    }
    
    // ==================== 分类漫画加载 ====================
    
    /**
     * 分类漫画加载配置
     */
    categoryComics = {
        /**
         * 加载分类漫画
         * @param category {string} 分类名称
         * @param param {string|null} 分类参数
         * @param options {string[]} 选项值数组
         * @param page {number} 页码
         * @returns {Promise<{comics: Comic[], maxPage: number}>}
         */
        load: async (category, param, options, page) => {
            // 从选项获取排序方式
            let sort = options[0] || "update"
            
            // 构建请求 URL
            let url = new URL('https://example.com/api/comics')
            url.searchParams.set('page', page)
            url.searchParams.set('limit', 20)
            url.searchParams.set('sort', sort)
            
            if (param) {
                url.searchParams.set('category', param)
            }
            
            let res = await Network.get(url.toString())
            let data = JSON.parse(res.body)
            
            return {
                comics: data.list?.map(item => new Comic({
                    id: item.id,
                    title: item.title,
                    subTitle: item.author,
                    cover: item.cover,
                    tags: item.genres,
                    description: item.summary?.substring(0, 100),
                    updateTime: item.updated_at
                })) || [],
                maxPage: Math.ceil(data.total / 20)
            }
        },
        
        /**
         * 排序选项
         */
        optionList: [
            {
                label: "排序",
                options: [
                    "update-最新更新",
                    "popular-最受欢迎", 
                    "rating-最高评分",
                    "new-最新上架"
                ]
            }
        ],
        
        /**
         * 排行榜配置
         */
        ranking: {
            options: [
                "day-日榜",
                "week-周榜", 
                "month-月榜",
                "total-总榜"
            ],
            
            /**
             * 加载排行榜
             * @param option {string} 排行选项
             * @param page {number} 页码
             */
            load: async (option, page) => {
                let res = await Network.get(
                    `https://example.com/api/ranking/${option}?page=${page}&limit=20`
                )
                let data = JSON.parse(res.body)
                
                return {
                    comics: data.list?.map(item => new Comic({
                        id: item.id,
                        title: item.title,
                        subTitle: item.author,
                        cover: item.cover,
                        stars: item.rating ? item.rating / 2 : null
                    })) || [],
                    maxPage: Math.ceil(data.total / 20)
                }
            }
        }
    }
    
    // ==================== 搜索 ====================
    
    /**
     * 搜索配置
     */
    search = {
        /**
         * 加载搜索结果
         * @param keyword {string} 搜索关键词
         * @param options {string[]} 选项值数组
         * @param page {number} 页码
         * @returns {Promise<{comics: Comic[], maxPage: number}>}
         */
        load: async (keyword, options, page) => {
            // URL 编码关键词
            let encodedKeyword = encodeURIComponent(keyword)
            let sort = options[0] || "relevance"
            
            let url = `https://example.com/api/search?q=${encodedKeyword}` +
                      `&sort=${sort}&page=${page}&limit=20`
            
            let res = await Network.get(url)
            let data = JSON.parse(res.body)
            
            return {
                comics: data.results?.map(item => new Comic({
                    id: item.id,
                    title: item.title,
                    subTitle: item.author,
                    cover: item.cover,
                    tags: item.tags,
                    description: item.summary
                })) || [],
                maxPage: Math.ceil(data.total / 20)
            }
        },
        
        /**
         * 搜索选项
         */
        optionList: [
            {
                label: "排序",
                type: "select",  // select / multi-select / dropdown
                options: [
                    "relevance-相关度",
                    "time-更新时间",
                    "views-浏览量",
                    "rating-评分"
                ]
            }
        ],
        
        // 是否启用标签建议
        enableTagsSuggestions: true,
        
        /**
         * 标签建议点击处理
         * @param namespace {string} 标签命名空间
         * @param tag {string} 标签名
         * @returns {string} 插入搜索框的文本
         */
        onTagSuggestionSelected: (namespace, tag) => {
            return `${namespace}:${tag}`
        }
    }
    
    // ==================== 漫画详情 ====================
    
    /**
     * 漫画详情配置
     */
    comic = {
        /**
         * 加载漫画详情
         * @param id {string} 漫画ID
         * @returns {Promise<ComicDetails>}
         */
        loadInfo: async (id) => {
            let [infoRes, chaptersRes] = await Promise.all([
                Network.get(`https://example.com/api/comic/${id}`),
                Network.get(`https://example.com/api/comic/${id}/chapters`)
            ])
            
            let info = JSON.parse(infoRes.body).data
            let chaptersData = JSON.parse(chaptersRes.body).data
            
            // 构建章节列表
            let chapters = {}
            chaptersData?.forEach(ch => {
                chapters[ch.id] = ch.title
            })
            
            // 构建标签
            let tags = {
                "作者": info.authors || [],
                "题材": info.genres || [],
                "状态": [info.status === 'ongoing' ? '连载中' : '已完结']
            }
            
            return new ComicDetails({
                title: info.title,
                subtitle: info.authors?.join(", ") || "",
                cover: info.cover,
                description: info.summary || "暂无简介",
                tags: tags,
                chapters: chapters,
                isFavorite: info.is_favorite,
                thumbnails: info.preview_images,
                stars: info.rating ? info.rating / 2 : null,
                updateTime: info.updated_at,
                uploadTime: info.created_at,
                url: `https://example.com/comic/${id}`,
                maxPage: chaptersData?.length || 0
            })
        },
        
        /**
         * 加载章节图片
         * @param comicId {string} 漫画ID
         * @param epId {string} 章节ID
         * @returns {Promise<{images: string[]}>}
         */
        loadEp: async (comicId, epId) => {
            let res = await Network.get(
                `https://example.com/api/comic/${comicId}/chapter/${epId}`
            )
            let data = JSON.parse(res.body)
            
            // 返回图片 URL 列表
            return {
                images: data.images?.map(img => img.url) || []
            }
        },
        
        /**
         * 图片加载配置
         * 用于设置图片加载时的 headers（如 Referer）
         * @param url {string} 图片URL
         * @param comicId {string} 漫画ID
         * @param epId {string} 章节ID
         * @returns {Object}
         */
        onImageLoad: (url, comicId, epId) => {
            return {
                headers: {
                    "Referer": "https://example.com"
                }
            }
        },
        
        /**
         * 标签点击处理
         * @param namespace {string} 标签命名空间
         * @param tag {string} 标签名
         * @returns {Object} 跳转目标
         */
        onClickTag: (namespace, tag) => {
            return {
                page: "search",
                keyword: tag
            }
        }
    }
}

// ==================== 创建实例 ====================
// 必须创建 source 实例并赋值给全局变量
const source = new ComicSourceTemplate()
