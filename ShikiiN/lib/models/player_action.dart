/// 所有可触发的命令（契约 §1）。键位/右键菜单/控制条都引用这些标识。
///
/// 只保留内置播放器需要的动作；打开文件/文件夹、面板、播放顺序、A-B 循环、
/// 字幕延迟、章节、截图/GIF、片头片尾、音量增强、均衡器等已随功能删除。
enum PlayerAction {
  playPause,
  seekForward,
  seekBackward,
  volumeUp,
  volumeDown,
  toggleMute,
  toggleFullscreen,
  exitFullscreen,
  nextItem,
  previousItem,
  cycleAudioTrack,
  cycleSubtitleTrack,
  openSettings,
  closeVideo,
  togglePip,
  toggleAlwaysOnTop,
  toggleStats,
  openSubtitleFile,
  toggleAnime4k,
}

extension PlayerActionLabel on PlayerAction {
  String get label => switch (this) {
        PlayerAction.playPause => '播放/暂停',
        PlayerAction.seekForward => '快进',
        PlayerAction.seekBackward => '快退',
        PlayerAction.volumeUp => '音量+',
        PlayerAction.volumeDown => '音量-',
        PlayerAction.toggleMute => '静音切换',
        PlayerAction.toggleFullscreen => '全屏切换',
        PlayerAction.exitFullscreen => '退出全屏',
        PlayerAction.nextItem => '下一集',
        PlayerAction.previousItem => '上一集',
        PlayerAction.cycleAudioTrack => '切换音轨',
        PlayerAction.cycleSubtitleTrack => '切换字幕',
        PlayerAction.openSettings => '设置',
        PlayerAction.closeVideo => '关闭视频',
        PlayerAction.togglePip => '画中画',
        PlayerAction.toggleAlwaysOnTop => '窗口置顶',
        PlayerAction.toggleStats => '视频数据',
        PlayerAction.openSubtitleFile => '加载字幕文件',
        PlayerAction.toggleAnime4k => '超分',
      };
}
