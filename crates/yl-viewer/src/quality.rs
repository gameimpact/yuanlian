use anyhow::{bail, Context, Result};
use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};
use yl_proto::{
    read_message, write_message, ClientHello, ClientMessage, ServerMessage, PROTOCOL_VERSION,
    TLS_SERVER_NAME,
};
use yl_runtime::OwnedProcess;

pub fn run(args: &super::Args, fingerprint: [u8; 32]) -> Result<()> {
    let exe = args
        .moonlight
        .as_ref()
        .context("--mode quality requires --moonlight <fixed Moonlight.exe>")?
        .canonicalize()?;
    yl_runtime::verify_component(&exe, "moonlight")?;
    let base = std::env::var_os("LOCALAPPDATA").context("LOCALAPPDATA missing")?;
    let base = Path::new(&base).join("YuanLian/quality-client-sessions");
    std::fs::create_dir_all(&base)?;
    let directory = tempfile::Builder::new()
        .prefix("client-")
        .tempdir_in(base)?;
    let cwd = directory.path();
    std::fs::write(cwd.join("portable.dat"), [])?;
    // Official Moonlight generates its own RSA identity. Never read/send its key.
    let mut bootstrap = OwnedProcess::start(
        &exe,
        &["list".into(), "--csv".into(), "127.0.0.1:9".into()],
        cwd,
        false,
    )?;
    let ini = cwd.join("Moonlight Game Streaming Project/Moonlight.ini");
    let deadline = Instant::now() + Duration::from_secs(20);
    let certificate = loop {
        if let Ok(cert) = yl_runtime::public_certificate(&ini) {
            break cert;
        }
        if Instant::now() > deadline || bootstrap.poll()?.is_some() {
            bail!("Moonlight identity initialization failed");
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    drop(bootstrap);
    // Process is gone before we update its dedicated, disposable configuration.
    std::thread::sleep(Duration::from_millis(100));
    tokio::runtime::Builder::new_current_thread().enable_all().build()?.block_on(async {
        let tcp = tokio::time::timeout(Duration::from_secs(10),tokio::net::TcpStream::connect(&args.connect)).await??;
        let remote = tcp.peer_addr()?;
        if !remote.is_ipv4(){bail!("quality adapter currently requires IPv4");}
        tcp.set_nodelay(true)?;
        let connector = tokio_rustls::TlsConnector::from(super::net::client_config(fingerprint)?);
        let mut stream = connector.connect(rustls::pki_types::ServerName::try_from(TLS_SERVER_NAME.to_string())?,tcp).await?;
        let ticket = args.ticket.clone().or_else(||std::env::var("YUANLIAN_SESSION_TICKET").ok()).context("quality requires a session ticket")?;
        write_message(&mut stream,&ClientMessage::Hello(ClientHello {
            protocol_version:PROTOCOL_VERSION,client_name:args.name.clone(),client_id:"yl-quality-viewer".into(),
            request_input:!args.view_only,features:yl_proto::FEATURE_SESSION_TICKET,
            session_ticket:Some(ticket),session_nonce:args.nonce.clone(),mode:"quality".into(),quality_certificate:certificate,
        })).await?;
        let message = tokio::time::timeout(Duration::from_secs(50),read_message::<_,ServerMessage>(&mut stream)).await??;
        let (port,cert,uuid) = match message {
            Some(ServerMessage::QualityReady {port,server_certificate,server_uuid,..})=>(port,server_certificate,server_uuid),
            Some(ServerMessage::Error{code,..})=>bail!("quality authorization failed: {}",code.as_str()),
            _=>bail!("Host did not return an authorized quality endpoint"),
        };
        if cert.len()>8192 || !cert.starts_with("-----BEGIN CERTIFICATE-----") || uuid.len()!=36 {bail!("invalid quality endpoint identity");}
        let host = remote.ip().to_string();
        let mut file = std::fs::OpenOptions::new().append(true).open(&ini)?;
        write!(file,"\n[hosts]\nsize=1\n1\\hostname=YuanLian authorized quality\n1\\uuid={uuid}\n1\\manualaddress={host}\n1\\manualport={port}\n1\\localaddress={host}\n1\\localport={port}\n1\\nvidiasw=false\n1\\srvcert={}\n",yl_runtime::qt_bytes(&cert))?;
        file.sync_all()?; drop(file);
        let launch = vec!["--resolution".into(),"1920x1080".into(),"--fps".into(),"60".into(),"--bitrate".into(),"20000".into(),
            "--display-mode".into(),"windowed".into(),"--performance-overlay".into(),"stream".into(),format!("{host}:{port}"),"Desktop".into()];
        let mut child = OwnedProcess::start(&exe,&launch,cwd,false)?;
        println!("official_moonlight_pid={}",child.pid());
        println!("Host 已授权质量视频串流；实际首帧/FPS/硬解请查看 Moonlight。关闭窗口结束会话。");
        let (mut reader,mut writer) = tokio::io::split(stream);
        let (tx,mut rx)=tokio::sync::mpsc::channel(8);
        let reader_task=tokio::spawn(async move {while let Ok(Some(msg))=read_message::<_,ServerMessage>(&mut reader).await {if tx.send(msg).await.is_err(){break;}}});
        let mut timer=tokio::time::interval(Duration::from_millis(250));
        let mut last_pong=Instant::now(); let mut ping_at=Instant::now(); let mut nonce=0;
        let result=loop {
            tokio::select! {
                msg=rx.recv()=>match msg {
                    Some(ServerMessage::Pong{..})=>last_pong=Instant::now(),
                    Some(ServerMessage::Error{code,..})=>break Err(anyhow::anyhow!("Host ended quality: {}",code.as_str())),
                    Some(ServerMessage::Bye{..})|None=>break Err(anyhow::anyhow!("Host disconnected")),
                    _=>break Err(anyhow::anyhow!("unexpected quality control message")),
                },
                _=timer.tick()=> {
                    if let Some(code)=child.poll()? {break if code==0 {Ok(())}else{Err(anyhow::anyhow!("Moonlight exited ({code})"))};}
                    if last_pong.elapsed()>Duration::from_secs(8){break Err(anyhow::anyhow!("quality control heartbeat lost"));}
                    if ping_at.elapsed()>Duration::from_secs(2){nonce+=1;write_message(&mut writer,&ClientMessage::Ping{nonce}).await?;ping_at=Instant::now();}
                }
            }
        };
        // Host media/input is already closed. Give the owned GUI a bounded
        // normal shutdown to flush its numeric decoder/render counters.
        child.request_close();
        let deadline=Instant::now()+Duration::from_millis(800);
        while Instant::now()<deadline && child.poll()?.is_none(){tokio::time::sleep(Duration::from_millis(20)).await;}
        drop(child);reader_task.abort();
        let _=write_message(&mut writer,&ClientMessage::Bye).await;
        result
    })
}
