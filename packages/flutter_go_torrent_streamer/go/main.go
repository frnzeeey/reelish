package main

/*
#include <stdlib.h>
#include <android/log.h>

static void android_log(const char* msg) {
    __android_log_print(ANDROID_LOG_DEBUG, "GoTorrent", "%s", msg);
}
*/
import "C"
import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unsafe"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"golang.org/x/time/rate"
)

// 状态常量
const (
	StateInitializing = "Initializing" // Initializing // 初始化中
	StateMetadata     = "Metadata"     // Fetching metadata // 获取元数据中 (Resolving)
	StateReady        = "Ready"        // Ready to start // 准备就绪
	StateDownloading  = "Downloading"  // Downloading // 下载中
	StateSeeding      = "Seeding"      // Seeding (Completed) // 做种中 (下载完成)
	StatePaused       = "Paused"       // Paused // 暂停
	StateStopped      = "Stopped"      // Stopped // 停止
	StateChecking     = "Checking"     // Checking files // 校验中
	StateError        = "Error"        // Error occurred // 错误
	StatePending      = "Pending"      // Pending in queue // 排队中
)

// 全局配置
type StreamerConfig struct {
	DownloadSpeedLimit int64  `json:"downloadSpeedLimit"` // Bytes per second // 字节/秒
	UploadSpeedLimit   int64  `json:"uploadSpeedLimit"`   // Bytes per second // 字节/秒
	ConnectionsLimit   int    `json:"connectionsLimit"`   // Max connections per torrent // 每个种子的最大连接数
	Port               int    `json:"port"`               // Listen port (0 for random) // 监听端口 (0 表示随机)
	UserAgent          string `json:"userAgent"`          // Client User-Agent // 客户端标识
	MaxActiveDownloads int    `json:"maxActiveDownloads"` // Max active downloads // 最大同时下载数
}

// StreamStatus defines the JSON structure for status updates.
// StreamStatus 定义状态更新的 JSON 结构
type StreamStatus struct {
	Progress      float64 `json:"progress"`
	Peers         int     `json:"peers"`
	Seeds         int     `json:"seeds"`
	Downloaded    int64   `json:"downloaded"`
	Total         int64   `json:"total"`
	State         string  `json:"state"`
	DownloadSpeed int64   `json:"downloadSpeed"`
	ETA           int64   `json:"eta"` // Remaining time in seconds, -1 if unknown // 剩余时间 (秒)，-1 表示未知
}

// TorrentFile defines the JSON structure for a file in the torrent.
// TorrentFile 定义种子中文件的 JSON 结构
type TorrentFile struct {
	Index int    `json:"index"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
}

// SessionInfo defines the summary information for a session.
// SessionInfo 定义会话的摘要信息
type SessionInfo struct {
	ID            string  `json:"id"`
	Name          string  `json:"name"`
	State         string  `json:"state"`
	Progress      float64 `json:"progress"`
	DownloadSpeed int64   `json:"downloadSpeed"`
	Peers         int     `json:"peers"`
	Seeds         int     `json:"seeds"`
	ETA           int64   `json:"eta"`
	Mode          string  `json:"mode"` // "stream" 或 "download"
	URL           string  `json:"url"`
}

// 持久化存储结构
type PersistentSession struct {
	ID        string `json:"id"`
	MagnetURI string `json:"magnet"`
	SavePath  string `json:"savePath"`
	Mode      string `json:"mode"`
	Paused    bool   `json:"paused"`
}

// StreamerSession represents a single BitTorrent streaming session.
// StreamerSession 代表单个 BT 流媒体会话
type StreamerSession struct {
	ID            string
	Client        *torrent.Client
	Torrent       *torrent.Torrent
	Server        *http.Server
	ServerPort    int
	LastError     error
	State         string
	SelectedFile  *torrent.File
	SelectedIndex int
	Mode          string // "stream" 或 "download"
	MagnetURI     string
	SavePath      string
	
	// 速度计算
	LastBytes     int64
	LastTime      time.Time
	CurrentSpeed  int64

	DownloadLimiter *rate.Limiter
	UploadLimiter   *rate.Limiter

	mu sync.RWMutex
}

// SessionManager manages multiple streaming sessions.
// SessionManager 管理多个流媒体会话
type SessionManager struct {
	sessions   map[string]*StreamerSession
	mu         sync.RWMutex
	configPath string
	config     StreamerConfig

	// Global Client for all sessions
	Client                *torrent.Client
	GlobalDownloadLimiter *rate.Limiter
	GlobalUploadLimiter   *rate.Limiter
}

// 检查队列并启动等待中的会话
func (sm *SessionManager) processQueue() {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	// 1. 统计活跃下载数
	activeCount := 0
	for _, s := range sm.sessions {
		s.mu.RLock()
		state := s.State
		s.mu.RUnlock()
		
		if state == StateInitializing || state == StateMetadata || state == StateReady || state == StateDownloading {
			activeCount++
		}
	}

	maxActive := sm.config.MaxActiveDownloads
	if maxActive <= 0 {
		maxActive = 3 // 默认 3
	}

	// 2. 启动排队会话
	if activeCount < maxActive {
		slotsAvailable := maxActive - activeCount
		
		for _, s := range sm.sessions {
			if slotsAvailable <= 0 {
				break
			}

			s.mu.Lock()
			if s.State == StatePending {
				s.State = StateInitializing
				s.mu.Unlock()
				
				go s.startDownloadInternal()
				
				slotsAvailable--
			} else {
				s.mu.Unlock()
			}
		}
	}
}

// 手动从 Magnet URI 创建 TorrentSpec
func createSpecFromMagnet(uri string) (*torrent.TorrentSpec, error) {
	m, err := metainfo.ParseMagnetUri(uri)
	if err != nil {
		return nil, err
	}
	trackers := make([][]string, len(m.Trackers))
	for i, tr := range m.Trackers {
		trackers[i] = []string{tr}
	}
	
	// 添加公共 Trackers
	publicTrackers := []string{
		"udp://tracker.opentrackr.org:1337/announce",
		"udp://9.rarbg.com:2810/announce",
		"udp://tracker.openbittorrent.com:80/announce",
		"http://tracker.openbittorrent.com:80/announce",
		"udp://opentracker.i2p.rocks:6969/announce",
		"udp://tracker.internetwarriors.net:1337/announce",
		"udp://tracker.leechers-paradise.org:6969/announce",
		"udp://coppersurfer.tk:6969/announce",
		"udp://tracker.zer0day.to:1337/announce",
	}
	
	for _, tr := range publicTrackers {
		found := false
		for _, existing := range m.Trackers {
			if existing == tr {
				found = true
				break
			}
		}
		if !found {
			trackers = append(trackers, []string{tr})
		}
	}

	return &torrent.TorrentSpec{
		InfoHash:    m.InfoHash,
		Trackers:    trackers,
		DisplayName: m.DisplayName,
	}, nil
}

// 内部方法：添加种子并开始下载
func (s *StreamerSession) startDownloadInternal() {
	// 重新添加 Torrent
	spec, err := createSpecFromMagnet(s.MagnetURI)
	if err != nil {
		s.mu.Lock()
		s.State = StateError
		s.LastError = err
		s.mu.Unlock()
		GetManager().processQueue()
		return
	}
	
	
	t, _, err := s.Client.AddTorrentSpec(spec)
	if err != nil {
		s.mu.Lock()
		s.State = StateError
		s.LastError = err
		s.mu.Unlock()
		GetManager().processQueue()
		return
	}

	s.mu.Lock()
	s.Torrent = t
	s.State = StateMetadata
	s.mu.Unlock()

	go func() {
		select {
		case <-t.GotInfo():
			s.mu.Lock()
			s.State = StateReady
			mode := s.Mode
			s.mu.Unlock()
			
			if mode == "download" {
				t.DownloadAll()
			}

		case <-time.After(60 * time.Second):
			s.mu.Lock()
			s.State = StateError
			s.mu.Unlock()
		}
	
	}()
}

var (
	manager          *SessionManager
	once             sync.Once
	globalConfigPath string
)

//export Init
// 初始化配置路径
func Init(configDir *C.char) {
	if configDir != nil {
		dir := C.GoString(configDir)
		globalConfigPath = filepath.Join(dir, "sessions.json")
	}
}

// 获取单例会话管理器
func GetManager() *SessionManager {
	once.Do(func() {
		fmt.Println("[Go] GetManager sync.Once executing - Initializing SessionManager")
		if globalConfigPath == "" {
			// 默认当前目录
			globalConfigPath = "sessions.json"
		}

		manager = &SessionManager{
			sessions:   make(map[string]*StreamerSession),
			configPath: globalConfigPath,
		}
		
		manager.initGlobalClient()
		manager.loadSessions()
		go manager.startSpeedMonitor()
	})
	return manager
}

// 输出日志到 logcat
func Log(msg string) {
	cMsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cMsg))
	C.android_log(cMsg)
}

// 初始化全局 Torrent 客户端
func (sm *SessionManager) initGlobalClient() {
	Log("[Go] initGlobalClient called")
	if sm.Client != nil {
		Log("[Go] Client already initialized!")
		return
	}
	cfg := torrent.NewDefaultClientConfig()
	
	// 设置 DataDir (优先使用 configDir)
	baseDir := os.TempDir()
	if globalConfigPath != "" && globalConfigPath != "sessions.json" {
		baseDir = filepath.Dir(globalConfigPath)
	}
	
	cfg.DataDir = filepath.Join(baseDir, "flutter_torrent_streamer_global")
	err := os.MkdirAll(cfg.DataDir, 0755)
	if err != nil {
		Log("[Go] Error creating DataDir: " + err.Error())
	} else {
		Log("[Go] DataDir created at: " + cfg.DataDir)
	}

	// 1. IPv4 配置
	cfg.DisableIPv6 = false

	// 2. 随机端口
	cfg.ListenPort = 0
	
	// 3. 开启节点发现 (DHT, PEX, etc.)
	cfg.NoDHT = false
	cfg.DisableTrackers = false
	cfg.DisableWebseeds = false
	cfg.DisablePEX = false

	// Apply global configuration
	if sm.config.UserAgent != "" {
		cfg.HTTPUserAgent = sm.config.UserAgent
	}
	if sm.config.ConnectionsLimit > 0 {
		cfg.EstablishedConnsPerTorrent = sm.config.ConnectionsLimit
	}

	// Global Rate limits
	sm.GlobalDownloadLimiter = rate.NewLimiter(rate.Inf, 64*1024) // Burst 64KB
	if sm.config.DownloadSpeedLimit > 0 {
		sm.GlobalDownloadLimiter.SetLimit(rate.Limit(sm.config.DownloadSpeedLimit))
	}
	cfg.DownloadRateLimiter = sm.GlobalDownloadLimiter

	sm.GlobalUploadLimiter = rate.NewLimiter(rate.Inf, 64*1024) // Burst 64KB
	if sm.config.UploadSpeedLimit > 0 {
		sm.GlobalUploadLimiter.SetLimit(rate.Limit(sm.config.UploadSpeedLimit))
	}
	cfg.UploadRateLimiter = sm.GlobalUploadLimiter
	
	client, err := torrent.NewClient(cfg)
	if err != nil {
		fmt.Println("[Go] Error initializing global client:", err)
	} else {
		fmt.Println("[Go] Global client initialized successfully on port", client.LocalPort())
	}
	sm.Client = client
}

// 定时更新会话速度
func (sm *SessionManager) startSpeedMonitor() {
	ticker := time.NewTicker(time.Second)
	for range ticker.C {
		sm.mu.Lock()
		for _, s := range sm.sessions {
			s.mu.Lock()
			if s.Torrent != nil {
				bytes := s.Torrent.BytesCompleted()
				now := time.Now()
				if !s.LastTime.IsZero() {
					duration := now.Sub(s.LastTime).Seconds()
					if duration >= 0.5 { // 避免过短时间间隔
						diff := bytes - s.LastBytes
						if diff < 0 { diff = 0 } // 防止重启/校验时出现负数
						s.CurrentSpeed = int64(float64(diff) / duration)
						
						s.LastBytes = bytes
						s.LastTime = now
					}
				} else {
					s.LastBytes = bytes
					s.LastTime = now
				}
			}
			s.mu.Unlock()
		}
		sm.mu.Unlock()
	}
}

// 保存会话列表到 JSON
func (sm *SessionManager) saveSessions() {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	var persistentList []PersistentSession
	for _, s := range sm.sessions {
		s.mu.RLock()
		persistentList = append(persistentList, PersistentSession{
			ID:        s.ID,
			MagnetURI: s.MagnetURI,
			SavePath:  s.SavePath,
			Mode:      s.Mode,
			Paused:    s.State == StatePaused,
		})
		s.mu.RUnlock()
	}

	data, err := json.MarshalIndent(persistentList, "", "  ")
	if err != nil {
		fmt.Println("Error serializing sessions:", err)
		return
	}

	// Write to file
	err = os.WriteFile(sm.configPath, data, 0644)
	if err != nil {
		fmt.Println("Error saving sessions to", sm.configPath, ":", err)
	}
}

// 从 JSON 恢复会话
func (sm *SessionManager) loadSessions() {
	data, err := os.ReadFile(sm.configPath)
	if err != nil {
		if !os.IsNotExist(err) {
			fmt.Println("Error reading sessions:", err)
		}
		return
	}

	var persistentList []PersistentSession
	if err := json.Unmarshal(data, &persistentList); err != nil {
		fmt.Println("Error parsing sessions:", err)
		return
	}

	fmt.Println("Restoring", len(persistentList), "sessions...")
	for _, p := range persistentList {

		go func(p PersistentSession) {
			session, err := sm.createSessionInternal(p.SavePath, p.ID)
			if err != nil {
				fmt.Println("Failed to restore session", p.ID, ":", err)
				return
			}
			
			session.mu.Lock()
			session.MagnetURI = p.MagnetURI
			session.Mode = p.Mode
			session.mu.Unlock()

			// Check if it was paused
			if p.Paused {
				session.mu.Lock()
				session.State = StatePaused
				session.mu.Unlock()
				// Do not start downloading
				return
			}
			
			session.mu.Lock()
			session.State = StatePending // Default to Pending on restore
			session.mu.Unlock()
			
			// Trigger queue processing
			sm.processQueue()
		}(p)
	}
}

//export Configure
// 导出函数：更新全局配置 (JSON)
func Configure(configJson *C.char) *C.char {
	jsonStr := C.GoString(configJson)
	var newConfig StreamerConfig
	if err := json.Unmarshal([]byte(jsonStr), &newConfig); err != nil {
		return C.CString("Config parse error: " + err.Error())
	}

	mgr := GetManager()
	mgr.mu.Lock()
	mgr.config = newConfig
	
	// Update global limits
	if mgr.GlobalDownloadLimiter != nil {
		if newConfig.DownloadSpeedLimit > 0 {
			mgr.GlobalDownloadLimiter.SetLimit(rate.Limit(newConfig.DownloadSpeedLimit))
		} else {
			mgr.GlobalDownloadLimiter.SetLimit(rate.Inf)
		}
	}
	
	if mgr.GlobalUploadLimiter != nil {
		if newConfig.UploadSpeedLimit > 0 {
			mgr.GlobalUploadLimiter.SetLimit(rate.Limit(newConfig.UploadSpeedLimit))
		} else {
			mgr.GlobalUploadLimiter.SetLimit(rate.Inf)
		}
	}

	// Trigger queue processing in case MaxActiveDownloads increased
	go mgr.processQueue()

	mgr.mu.Unlock()

	return C.CString("Success")
}

// 创建新会话
func (sm *SessionManager) CreateSession(savePath string) (*StreamerSession, error) {
	id := fmt.Sprintf("%d", time.Now().UnixNano())
	session, err := sm.createSessionInternal(savePath, id)
	return session, err
}

// 内部辅助函数：创建会话对象
func (sm *SessionManager) createSessionInternal(savePath string, id string) (*StreamerSession, error) {
	sm.mu.RLock()
	sm.mu.RUnlock()

	if sm.Client == nil {
		return nil, fmt.Errorf("global torrent client not initialized")
	}

	session := &StreamerSession{
		ID:              id,
		Client:          sm.Client, // Shared client
		State:           StateInitializing,
		SelectedIndex:   -1,
		Mode:            "stream", // 默认流媒体模式
		SavePath:        savePath,
		DownloadLimiter: sm.GlobalDownloadLimiter,
		UploadLimiter:   sm.GlobalUploadLimiter,
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	session.ServerPort = listener.Addr().(*net.TCPAddr).Port

	mux := http.NewServeMux()
	mux.HandleFunc("/stream", session.streamHandler)

	session.Server = &http.Server{
		Handler: mux,
	}

	go func() {
		// 启动 HTTP 服务
		if err := session.Server.Serve(listener); err != nil && err != http.ErrServerClosed {
			fmt.Printf("HTTP server error for session %s: %v\n", session.ID, err)
		}
	}()

	sm.mu.Lock()
	sm.sessions[session.ID] = session
	sm.mu.Unlock()

	return session, nil
}

// 获取指定 ID 的会话
func (sm *SessionManager) GetSession(id string) *StreamerSession {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.sessions[id]
}

// 关闭并移除会话
func (sm *SessionManager) CloseSession(id string) {
	sm.mu.Lock()
	session, exists := sm.sessions[id]
	if exists {
		delete(sm.sessions, id)
	}
	sm.mu.Unlock()

	if exists {
		session.Close()
		// 删除后保存状态
		go sm.saveSessions()
	}
}

// 获取所有会话摘要
func (sm *SessionManager) GetAllSessions() []SessionInfo {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	var list []SessionInfo
	for _, s := range sm.sessions {
		s.mu.RLock()
		info := SessionInfo{
			ID:            s.ID,
			State:         s.State,
			Mode:          s.Mode,
			Name:          "Loading...",
			URL:           fmt.Sprintf("http://127.0.0.1:%d/stream", s.ServerPort),
			DownloadSpeed: s.CurrentSpeed,
			ETA:           -1,
		}
		if s.Torrent != nil && s.Torrent.Info() != nil {
			info.Name = s.Torrent.Info().Name

			total := s.Torrent.Length()
			downloaded := s.Torrent.BytesCompleted()
			if total > 0 {
				info.Progress = float64(downloaded) / float64(total) * 100
			}

			// 填充 Peers (Seeds 暂不区分)
			stats := s.Torrent.Stats()
			info.Peers = stats.ActivePeers
			info.Seeds = 0

			// 计算 ETA
			if s.CurrentSpeed > 0 && total > downloaded {
				info.ETA = (total - downloaded) / s.CurrentSpeed
			}
		}
		s.mu.RUnlock()
		list = append(list, info)
	}
	return list
}

// 暂停会话 (保留状态)
func (s *StreamerSession) Pause() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.State == StatePaused {
		return
	}

	if s.Torrent != nil {
		s.Torrent.Drop()
		s.Torrent = nil // Clear torrent handle
	}
	
	// 保持 Server 运行以便 UI 显示状态
	
	s.State = StatePaused
	s.CurrentSpeed = 0
	// 检查队列
	go GetManager().processQueue()
}

// 恢复会话
func (s *StreamerSession) Resume() {
	s.mu.Lock()
	if s.State != StatePaused {
		s.mu.Unlock()
		return
	}
	s.State = StatePending // Move to Pending first
	s.mu.Unlock() 

	// Try to process queue (will start if slots available)
	go GetManager().processQueue()
}

// 关闭会话资源
func (s *StreamerSession) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.Torrent != nil {
		// Drop the torrent from the client, but keep the client running!
		s.Torrent.Drop()
	}
	if s.Server != nil {
		s.Server.Close()
	}
	s.State = StateStopped
	
	// Check queue
	go GetManager().processQueue()
}

// 处理流媒体 HTTP 请求
func (s *StreamerSession) streamHandler(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	if s.Torrent == nil {
		s.mu.RUnlock()
		http.Error(w, "Torrent not ready", http.StatusServiceUnavailable)
		return
	}

	var fileToStream *torrent.File

	if s.SelectedFile != nil {
		fileToStream = s.SelectedFile
	} else {
		// 未选择则默认最大的文件
		var largestFile *torrent.File
		var maxSize int64
		for _, f := range s.Torrent.Files() {
			if f.Length() > maxSize {
				maxSize = f.Length()
				largestFile = f
			}
		}
		fileToStream = largestFile
	}
	s.mu.RUnlock()

	if fileToStream == nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	fileToStream.Download()
	reader := fileToStream.NewReader()
	reader.SetResponsive()
	defer reader.Close()

	http.ServeContent(w, r, fileToStream.Path(), time.Now(), reader)
}

//export StartStream
// 导出函数：启动下载/流媒体
func StartStream(magnetLink *C.char, savePath *C.char) *C.char {
	GetManager()
	
	path := ""
	if savePath != nil {
		path = C.GoString(savePath)
	}

	session, err := GetManager().CreateSession(path)
	if err != nil {
		return C.CString("Error: " + err.Error())
	}

	magnet := C.GoString(magnetLink)
	session.mu.Lock()
	session.MagnetURI = magnet
	session.State = StatePending
	session.mu.Unlock()

	// 保存新会话
	go GetManager().saveSessions()
	
	// 尝试启动
	go GetManager().processQueue()

	resp := map[string]string{
		"sessionId": session.ID,
		"url":       fmt.Sprintf("http://127.0.0.1:%d/stream", session.ServerPort),
	}
	b, _ := json.Marshal(resp)
	return C.CString(string(b))
}

//export GetStreamStatus
// 导出函数：获取会话状态
func GetStreamStatus(sessionId *C.char) *C.char {
	id := C.GoString(sessionId)
	session := GetManager().GetSession(id)

	if session == nil {
		status := StreamStatus{State: "NotFound"}
		b, _ := json.Marshal(status)
		return C.CString(string(b))
	}

	session.mu.RLock()
	defer session.mu.RUnlock()

	if session.Torrent == nil {
		status := StreamStatus{State: session.State}
		b, _ := json.Marshal(status)
		return C.CString(string(b))
	}

	t := session.Torrent
	stats := t.Stats()

	downloaded := t.BytesCompleted()
	total := t.Length()

	status := StreamStatus{
		Progress:      0,
		Peers:         stats.ActivePeers,
		Seeds:         0,
		Downloaded:    downloaded,
		Total:         total,
		State:         session.State,
		DownloadSpeed: session.CurrentSpeed,
		ETA:           -1,
	}

	if total > 0 {
		status.Progress = float64(downloaded) / float64(total) * 100
	}

	// 计算 ETA
	if session.CurrentSpeed > 0 && total > downloaded {
		status.ETA = (total - downloaded) / session.CurrentSpeed
	}

	// 动态计算状态
	if session.State == StateReady {
		if downloaded >= total && total > 0 {
			status.State = StateSeeding
		} else if stats.ActivePeers > 0 && downloaded < total {
			status.State = StateDownloading
		} else if stats.ActivePeers == 0 && downloaded < total {
			// 认为是 Stalled 或 Ready (无 Peers)
			status.State = StateReady 
		}
	} else {
		status.State = session.State
	}

	// 修正状态显示：有流量或下载模式且有连接时，显示为下载中
	if status.State != StateSeeding && status.State != StateDownloading {
		if session.SelectedFile != nil || session.Mode == "download" {
			if stats.ActivePeers > 0 {
				status.State = StateDownloading
			}
		}
	}

	b, _ := json.Marshal(status)
	return C.CString(string(b))
}

//export GetFiles
// 导出函数：获取文件列表
func GetFiles(sessionId *C.char) *C.char {
	id := C.GoString(sessionId)
	session := GetManager().GetSession(id)

	if session == nil {
		return C.CString("[]")
	}

	session.mu.RLock()
	defer session.mu.RUnlock()

	if session.Torrent == nil || session.Torrent.Info() == nil {
		return C.CString("[]")
	}

	var files []TorrentFile
	for i, f := range session.Torrent.Files() {
		files = append(files, TorrentFile{
			Index: i,
			Name:  f.DisplayPath(),
			Size:  f.Length(),
		})
	}

	b, _ := json.Marshal(files)
	return C.CString(string(b))
}

//export SelectFile
// 导出函数：选择播放文件
func SelectFile(sessionId *C.char, fileIndex int) *C.char {
	id := C.GoString(sessionId)
	session := GetManager().GetSession(id)

	if session == nil {
		return C.CString("Session not found")
	}

	session.mu.Lock()
	defer session.mu.Unlock()

	if session.Torrent == nil {
		return C.CString("Torrent not ready")
	}

	files := session.Torrent.Files()
	if fileIndex < 0 || fileIndex >= len(files) {
		return C.CString("Invalid file index")
	}

	session.SelectedFile = files[fileIndex]
	session.SelectedIndex = fileIndex

	// 优先下载
	session.SelectedFile.SetPriority(torrent.PiecePriorityNow)
	return C.CString("Success")
}

//export DownloadFile
// 导出函数：后台下载文件
func DownloadFile(sessionId *C.char, fileIndex int) *C.char {
	id := C.GoString(sessionId)
	session := GetManager().GetSession(id)

	if session == nil {
		return C.CString("Session not found")
	}

	session.mu.Lock()
	defer session.mu.Unlock()

	if session.Torrent == nil {
		return C.CString("Torrent not ready")
	}

	files := session.Torrent.Files()
	if fileIndex < 0 || fileIndex >= len(files) {
		return C.CString("Invalid file index")
	}

	// session.SelectedFile = files[fileIndex] // 不设置为选中播放
	session.Mode = "download"
	files[fileIndex].Download()
	
	// 保存模式变更
	go GetManager().saveSessions()

	return C.CString("Success")
}

//export GetAllSessions
// 导出函数：获取所有会话
func GetAllSessions() *C.char {
	sessions := GetManager().GetAllSessions()
	b, _ := json.Marshal(sessions)
	return C.CString(string(b))
}

//export PauseSession
// 导出函数：暂停会话
func PauseSession(sessionId *C.char) {
	id := C.GoString(sessionId)
	session := GetManager().GetSession(id)
	if session != nil {
		session.Pause()
		// 保存状态
		go GetManager().saveSessions()
	}
}

//export ResumeSession
// 导出函数：恢复会话
func ResumeSession(sessionId *C.char) {
	id := C.GoString(sessionId)
	session := GetManager().GetSession(id)
	if session != nil {
		session.Resume()
		// 保存状态
		go GetManager().saveSessions()
	}
}

//export StopClient
// 导出函数：停止会话
func StopClient(sessionId *C.char) {
	id := C.GoString(sessionId)
	GetManager().CloseSession(id)
}

//export FreeString
// 导出函数：释放 C 字符串
func FreeString(str *C.char) {
	C.free(unsafe.Pointer(str))
}

func main() {}
