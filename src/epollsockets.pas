unit epollsockets;

{$i ccwssettings.inc}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  baseunix,
  unix,
  linux,
  sockets,
  synsock,
  sslclass,
  logging;

const
  { maximum concurrent connections per thread }
  MaxConnectionsPerThread = 40000;
  { maxim number of epoll events that can be handled concurrently}
  MaxEpollEventsPerThread = 10000;

type
  TEPollSocket = class;
  TEpollWorkerThread = class;
  TEPollSocketEvent = procedure(Sender: TEPollSocket) of object;

  TEPollCallbackProc = procedure of object;

  { TEPollSocket }

  TEPollSocket = class
  private
    FOutbuffer: string;
    FOutbuffer2: string;
    FonDisconnect: TEPollSocketEvent;
    FParent: TEpollWorkerThread;
    FSocket: TSocket;
    FRemoteIP, FRemoteIPPort: string;
    FWantClose: Boolean;
    FIsSSL: Boolean;
    FSSLContext: TAbstractSSLContext;
    FSSL: TAbstractSSLSession;
    FWantSSL: Boolean;
    function GetClosed: Boolean;
  protected
    { internal callback function that adds socket in parent thread }
    procedure AddCallback; virtual;
    { process incoming data - called by worker thread, has to be overridden }
    procedure ProcessData(const Data: string); overload; virtual;
    { if this function is overriden, the other ProcessData(string) function won't be called unless inherited form is called }
    procedure ProcessData(const Buffer: Pointer; BufferLength: Integer); overload; virtual;
    { reads up to Length(Data) bytes from socket - called by worker thread.
      'Data' acts as a temporary buffer }
    function ReadData(const Buffer: Pointer; BufferLength: Integer): Boolean;
    { returns true when the socket can be closed, and all outgoing data has
      been sent }
    function WantClose: Boolean;
    { returns true if socket can be closed. override this to add custom checks,
      is called by thread worker to determine if class can be removed from queue }
    function CheckTimeout: Boolean; virtual;
  public
    constructor Create(Socket: TSocket);
    destructor Destroy; override;
    { performs cleanup - closes socket, disposes any data that is held in class
      members. After cleanup, the class can be reused using .Reassign() }
    procedure Cleanup; virtual;
    { this frees the class. in derived classes this can be overridden to
      e.g. put this class instance back into a pool, instead of freeing }
    procedure Dispose; virtual;
    { flush data that needs to be written to the socket - can be called manually,
      but is also called from worker thread (e.g. when not all data can be sent
      in one pass) }
    function FlushSendbuffer: Boolean;
    { assigns a new socket to to reuse the class. Cleanup must have been called
      before }
    procedure Reassign(Socket: TSocket);
    { move socket to another worker thread }
    procedure Relocate(NewParent: TEpollWorkerThread);
    { marks the connection as "WantClosed". Remaining asynchronous send operations
      will be finished first before the socket is actually closed. this is done
      in the worker thread }
    procedure Close;
    { returns ip and port }
    function GetPeerName: string;
    { returns ip }
    function GetRemoteIP: string;
    { send data - if flush is true, data will be immediately written to the
      socket, or stored until FlushSendbuffer is called }
    procedure SendRaw(const Data: string; Flush: Boolean = True); overload;
    procedure SendRaw(const Data: Pointer; DataSize: Integer; Flush: Boolean = True); overload;
    { performs ssl handshake }
    procedure StartSSL;
    { cleans up ssl - you probably don't want to call this manually }
    procedure StopSSL;

    property Closed: Boolean read GetClosed;
    { actual socket handle }
    property Socket: TSocket read FSocket;
    { Parent Thread }
    property Parent: TEpollWorkerThread read FParent;
    { callback function when socket is closed }
    property OnDisconnect: TEPollSocketEvent read FonDisconnect write FOnDisconnect;
    { returns true if ssl has been loaded }
    property IsSSL: Boolean read FIsSSL;
    { if true, SSL handshake is performed }
    property WantSSL: Boolean read FWantSSL write FWantSSL;
    { the associated openssl context }
    property SSLContext: TAbstractSSLContext read FSSLContext write FSSLContext;
  end;

  { TCustomEpollHandler }

  TCustomEpollHandler = class
  private
    FInCallback: Boolean;
    FParent: TEpollWorkerThread;
    FHandles: array of THandle;
    FWantFree: Boolean;
  protected
    procedure AddHandle(Handle: THandle);
    procedure RemoveHandle(Handle: THandle);
    procedure DataReady(Event: epoll_event); virtual; abstract;
  public
    constructor Create(AParent: TEpollWorkerThread);
    destructor Destroy; override;
    procedure DelayedFree; virtual;
    property WantFree: Boolean read FWantFree;
    property InCallback: Boolean read FInCallback write FInCallback;
  end;

  { TEpollWorkerThread }

  TEpollWorkerThread = class(TThread)
  private
    FEpollFD: integer;
    FSocketCount: Integer;
    FSockets: array[0..MaxConnectionsPerThread-1] of TEPollSocket;
    FFreeQueuePos: Integer;
    FFreeQueue: array[0..MaxEpollEventsPerThread-1] of TObject;
    FEpollEvents: array[0..MaxEpollEventsPerThread-1] of epoll_event;
    FParent: TObject;
    FTicks: Integer;
    FTotalCount: Integer;
    FPipeInput,
    FPipeOutput: THandle;
    FOnConnection: TEPollSocketEvent;
    procedure RemoveSocket(Sock: TEPollSocket; doClose: Boolean = True; doFree: Boolean = true);
  protected
    { called inbetween epoll, checks for client timeouts }
    procedure ThreadTick; virtual;
    { Called inside thread before entering thread loop }
    procedure Initialize; virtual;
    { called after exiting thread loop }
    procedure Finalize; virtual;
    { overriden thread function }
    procedure Execute; override;
    { add socket - this is called from TEPollSocket-relocate within this thread }
    function AddSocket(Sock: TEPollSocket): Boolean;
  public
    constructor Create(aParent: TObject);
    destructor Destroy; override;
    { execute callback proc in thread }
    function Callback(Method: TEPollCallbackProc): Boolean;
    property EPollFD: integer read FEPollFD write FEpollFD;
    property OnConnection: TEPollSocketEvent read FOnConnection write FOnConnection;
    property Totalcount: Integer read FTotalCount;
    property Parent: TObject read FParent;
  end;

const
  { Default waiting time for epoll }
  EpollWaitTime = 100;

implementation

uses
  chakrawebsocket,
  webserver;

const
  { ticks until CheckTimeout function is called }
  ClientTickInterval = 1000 div EpollWaitTime;
  { Internal buffer size for a single read() call }
  InternalBufferSize = 65536;

{ TCustomEpollHandler }

procedure TCustomEpollHandler.AddHandle(Handle: THandle);
var
  i: Integer;
  event: epoll_event;
begin
  for i:=0 to Length(FHandles)-1 do
    if FHandles[i] = Handle then
      Exit;

  event.Events:=EPOLLIN or {EPOLLET or }EPOLLHUP;
  event.Data.ptr:=Self;

  if epoll_ctl(FParent.epollfd, EPOLL_CTL_ADD, Handle, @event)<0 then
  begin
    dolog(llDebug, ['epoll_ctl_add failed, error #', IntToStr(fpgeterrno), ' ', IntToStr(Handle)]);
  end else
  begin
    i:=Length(FHandles);
    Setlength(FHandles, i+1);
    FHandles[i]:=Handle;
  end;
end;

procedure TCustomEpollHandler.RemoveHandle(Handle: THandle);
var
  i: Integer;
begin
  for i:=0 to Length(FHandles)-1 do
    if FHandles[i] = Handle then
    begin
      FHandles[i]:=FHandles[Length(FHandles)-1];
      Setlength(FHandles, Length(FHandles)-1);
      if epoll_ctl(FParent.epollfd, EPOLL_CTL_DEL, Handle, nil)<0 then
        dolog(llError, ['Custom epoll_ctl_del failed #', IntToStr(fpgeterrno), ' ', IntToStr(Handle)]);
      Exit;
    end;
end;

constructor TCustomEpollHandler.Create(AParent: TEpollWorkerThread);
begin
  FParent:=AParent;
end;

destructor TCustomEpollHandler.Destroy;
begin
  if FInCallback then
    dolog(llFatal, 'CustomEpollHandler.Destroy in callback');

  while Length(FHandles)>0 do
    RemoveHandle(FHandles[Length(FHandles)-1]);

  inherited Destroy;
end;

procedure TCustomEpollHandler.DelayedFree;
begin
  if FInCallback and FWantFree then
    Exit;

  if not FInCallback then
    Free
  else
    FWantFree:=True;
end;

{ TEPollSocket }

procedure TEPollSocket.AddCallback;
begin
  if not FParent.AddSocket(Self) then
  begin
    // dolog(llError, GetPeerName + ': Could not relocate to thread, dropping!');
    FParent:=nil;
    FWantclose:=True;
    Dispose;
  end;
end;

function TEPollSocket.GetClosed: Boolean;
begin
  result:=(FSocket = INVALID_SOCKET) or WantClose;
end;

procedure TEPollSocket.ProcessData(const Data: string);
begin

end;

procedure TEPollSocket.ProcessData(const Buffer: Pointer; BufferLength: Integer
  );
var
  Temp: string;
begin
  Setlength(Temp,BufferLength);
  Move(Buffer^, Temp[1], BufferLength);
  ProcessData(Temp);
  Temp:='';
end;


procedure TEPollSocket.SendRaw(const Data: string; Flush: Boolean);
begin
  if FWantClose then
    Exit;

  if Assigned(FSSL) and FSSL.WantWrite then
  begin
    FOutbuffer2:=FOutbuffer2 + data;
    Exit;
  end;

  FOutbuffer:=FOutbuffer + data;
  if Flush then
    FlushSendbuffer;
end;

procedure TEPollSocket.SendRaw(const Data: Pointer; DataSize: Integer;
  Flush: Boolean);
var
  start: Integer;
begin
  if Assigned(FSSL) and FSSL.WantWrite then
  begin
    start:=Length(FOutBuffer2);
    SetLength(FOutBuffer2, start + DataSize);
    Move(Data^, FOutBuffer2[start + 1], DataSize);
    Exit;
  end;

  start:=Length(FOutBuffer);
  SetLength(FOutBuffer, start + DataSize);
  Move(Data^, FOutBuffer[start + 1], DataSize);

  if Flush then
    FlushSendbuffer;
end;

function TEPollSocket.ReadData(const Buffer: Pointer; BufferLength: Integer
  ): Boolean;
var
  bufferRead, err: Integer;
begin
  if FIsSSL then
  begin
    bufferRead:=FSSL.Read(Buffer, BufferLength);
    if bufferRead<=0 then
    begin
      if FSSL.WantClose then
       Close;
      result:=False;
    end else
    begin
      ProcessData(Buffer, bufferRead);
      result:=True;
    end;
    Exit;
  end;

  bufferRead := fprecv(FSocket, Buffer,BufferLength, MSG_DONTWAIT or MSG_NOSIGNAL);
  if bufferRead<=0 then
  begin
    if bufferRead<0 then
    begin
      err:=fpgeterrno;
      case err of
        ESysEWOULDBLOCK: result:=True;
        ESysEPIPE,
        ESysECONNRESET,
        ESysENOTCONN,
        ESysETIMEDOUT:
        begin
          result:=False;
          FWantClose:=True;
        end;
        else
        begin
          dolog(llDebug, [GetPeerName, ': error in fprecv #', IntToStr(err)]);
          result:=False;
          FWantClose:=True;
        end;
      end;
    end else
    begin
      // connection closed
      result:=False;
      FWantClose:=True;
      // discard any buffer that is left to send
      FOutbuffer:='';
      FOutbuffer2:='';
    end;
  end else
  begin
    ProcessData(Buffer, bufferRead);
    result:=True;
  end;
end;

function TEPollSocket.FlushSendbuffer: Boolean;
var
  i, err: Integer;
  event: epoll_event;
begin
  result:=False;

  if not Assigned(FParent) then
    Exit;

  if (Length(FOutbuffer)>0) or (Assigned(FSSL) and FSSL.WantWrite)
  then begin
    if FIsSSL then
    begin
      // openssl might want to write something even when we have no data
      if Length(FOutBuffer)=0 then
        i:=FSSL.Write(nil, 0)
      else
        i:=FSSL.Write(@FOutBuffer[1], Length(FOutbuffer));

      if i<=0 then
      begin
        if FSSL.WantClose then
         Close;
        i:=0;
      end else
        result:=True;
    end else
    begin
      i:=fpsend(FSocket, @FOutbuffer[1], Length(FOutbuffer), MSG_DONTWAIT or MSG_NOSIGNAL);
      if i=0 then
      begin
        // I don't think that should ever happen according to manpages
        dolog(llDebug, [GetPeerName, ': fpsend Could not send anything, #', IntToStr(fpgeterrno), ' ', IntToStr(i)]);
      end else
      if i<0 then
      begin
        err:=fpgeterrno;
        case err of
          //ESysEWOULDBLOCK: ; // do nothing
          ESysEPIPE,
          ESysECONNRESET,
          ESysENOTCONN,
          ESysETIMEDOUT:
          begin
            // connection is broken, close but don't be annoying about it
            i:=0;
            FWantClose:=True;
          end;
          ESysEAGAIN:
          begin
            i:=0;
            result:=True;
          end;
          // I don't think that should ever happen according to manpages
          else begin
            // unknown error, log
            dolog(llError, [GetPeerName, ': Error in fpsend #', IntToStr(err), ' ', IntToStr(i)]);
            FWantclose:=True;
            i:=-1;
          end;
        end;
      end else
        result := True;
    end;

    if result and (i>0) then
    begin
      Delete(FOutbuffer, 1, i);
    end;

    if (Length(FOutBuffer)>0) or (Assigned(FSSL)and FSSL.WantWrite)
    then begin
      event.Events:=EPOLLIN or EPOLLOUT;
      event.Data.ptr:=Self;
      if epoll_ctl(FParent.epollfd, EPOLL_CTL_MOD, FSocket, @event)<0 then
        dolog(llDebug, [GetPeerName, ': epoll_ctl_mod failed (epollin+epollout), error #', IntToStr(fpgeterrno)]);
    end else
    if (Length(FOutbuffer)=0)and(Length(FOutbuffer2)>0) then
    begin
      FOutbuffer:=FOutbuffer2;
      FOutbuffer2:='';
      FlushSendbuffer();
    end;
  end else
  begin
   event.Events:=EPOLLIN;
   event.Data.ptr:=Self;
   if epoll_ctl(FParent.epollfd, EPOLL_CTL_MOD, FSocket, @event)<0 then
     dolog(llDebug, [GetPeerName, ': epoll_ctl_mod failed (epollin), error #', IntToStr(fpgeterrno)]);
  end;
end;

constructor TEPollSocket.Create(Socket: TSocket);
begin
  FParent:=nil;
  FSocket:=Socket;
end;

function TEPollSocket.GetPeerName: string;
var
  len: integer;
  Name: TVarSin;
begin
  if FRemoteIPPort<>'' then
    result:=FRemoteIPPort
  else begin
    begin
      len := SizeOf(name);
      FillChar(name, len, 0);
      fpGetPeerName(FSocket, @name, @Len);
      FRemoteIP:=string(GetSinIP(Name));
      FRemoteIPPort:=FRemoteIP+'.'+string(IntToStr(GetSinPort(Name)));
      result:=FRemoteIPPort;
    end;
  end;
end;

function TEPollSocket.GetRemoteIP: string;
begin
  if FRemoteIP='' then
    GetPeerName;
  result:=FRemoteIP;
end;

procedure TEPollSocket.Relocate(NewParent: TEpollWorkerThread);
begin
  if Assigned(FParent) then
    FParent.RemoveSocket(Self, False, False);

  FParent:=NewParent;
  if not NewParent.Callback(@AddCallback) then
  begin
    dolog(llError, [GetPeerName, ': Callback for relocation failed, dropping!']);
    FParent:=nil;
    FWantClose:=True;
    Dispose;
  end;
end;

destructor TEPollSocket.Destroy;
begin
  Cleanup;
  inherited Destroy;
end;

procedure TEPollSocket.Reassign(Socket: TSocket);
begin
  if FSocket<>0 then
    raise Exception.Create('TEpollSocket.Reassign was called while still holding socket');
  FParent:=nil;
  FSocket:=Socket;
end;

procedure TEPollSocket.StartSSL;
begin
  if FIsSSL then
    Exit;
  FSSL:=FSSLContext.StartSession(FSocket, GetPeerName+': ');
  FIsSSL:=Assigned(fssl);
end;

procedure TEPollSocket.StopSSL;
begin
   if not FIsSSL then
     Exit;
  FSSL.Free;
  FIsSSL:=False;
  FSSL:=nil;
end;


procedure TEPollSocket.Cleanup;
begin
   if Assigned(FonDisconnect) then
     FonDisconnect(Self);

   if FIsSSL then
     StopSSL;
   if FSocket<>0 then
     fpclose(FSocket);
   FSocket:=0;
   FWantclose:=False;
   FOutbuffer:='';
   FOutbuffer2:='';
   FRemoteIP:='';
   FRemoteIPPort:='';
   FOnDisconnect:=nil;
end;

procedure TEPollSocket.Dispose;
begin
  Free;
end;

procedure TEPollSocket.Close;
begin
  FWantClose:=True;
end;

function TEPollSocket.WantClose: Boolean;
begin
  result:=(FOutbuffer='')and FWantclose;
end;

function TEPollSocket.CheckTimeout: Boolean;
begin
  result:=FWantClose;
end;

{ TEpollWorkerThread }

procedure TEpollWorkerThread.Execute;
var
  i, j: Integer;
  data: Pointer;
  conn: TEPollSocket;
  EpCallback: TEPollCallbackProc;
  event: epoll_event;
begin
  FillChar(event, SizeOf(Event), #0);
  epollfd:=epoll_create(MaxConnectionsPerThread);
  // add callback pipe
  event.Events:=EPOLLIN;
  event.Data.fd:=FPipeOutput;
  fpfcntl(FPipeOutput, F_SetFl, fpfcntl(FPipeOutput, F_GetFl) or O_NONBLOCK);
  if epoll_ctl(epollfd, EPOLL_CTL_ADD, FPipeOutput, @event)<0 then
  begin
    dolog(llError, ['epoll_ctl_add pipe failed, error #', IntToStr(fpgeterrno)]);
  end;

  GetMem(Data, InternalBufferSize);

  Initialize;

  try
  while (not Terminated) do
  begin
    FFreeQueuePos:=0;

    i := epoll_wait(epollfd, @FEpollEvents[0], MaxEpollEventsPerThread, EpollWaitTime);
    for j:=0 to i-1 do
    if FEpollEvents[j].Data.fd = FPipeOutput then
    begin
      // we only expect class function pointers from the callback pipe
      if FpRead(FEpollEvents[j].data.fd, EpCallback, SizeOf(EpCallback)) = SizeOf(EpCallback) then
      begin
        EpCallback();
      end else
        dolog(llError, 'Error reading epollworkerthread callback');
    end else
    if not Assigned((FEpollEvents[j].data.ptr)) then
    begin
      dolog(llError, 'Epoll event without handler received');
    end else
    if TObject(FEPollEvents[j].data.ptr) is TCustomEpollHandler then
    begin
      with TCustomEpollHandler(FEPollEvents[j].data.ptr) do
      begin
        InCallback:=True;
        DataReady(FEpollEvents[j]);
        InCallback:=False;
        if WantFree then
        begin
          FFreeQueue[FFreeQueuePos]:=TObject(FEPollEvents[j].data.ptr);
          Inc(FFreeQueuePos);
        end;
      end;
    end
    else
    begin
      conn:=TEPollSocket(FEpollEvents[j].data.ptr);

      if conn.FParent <> Self then
      begin
        dolog(llError, [conn.GetPeerName, ': got epoll message from connection located in different thread']);
      end else
      if (FEpollEvents[j].Events and EPOLLIN<>0) then
      begin
        conn.ReadData(Data, InternalBufferSize);
      end else if (FEpollEvents[j].Events and EPOLLOUT<>0) then
      begin
        conn.FlushSendbuffer;
      end else if (FEpollEvents[j].Events and EPOLLERR<>0) then
      begin
        dolog(llDebug, ['got epoll-error ', IntToStr(fpgeterrno)]);
        conn.FWantclose:=True;
      end else
      begin
        dolog(llDebug, ['unknown epoll-event ', IntToStr(FEpollEvents[j].Events)]);
        conn.FWantclose:=True;
      end;

      if (conn.FParent = Self) and (conn.WantClose) then
      begin
        FFreeQueue[FFreeQueuePos]:=conn;
        Inc(FFreeQueuePos);
      end;
    end;

    for i:=0 to FFreeQueuePos-1 do
      if FFreeQueue[i] is TEPollSocket then
        RemoveSocket(TEPollSocket(FFreeQueue[i]))
      else
        FFreeQueue[i].Free;

    ThreadTick;
  end;

  except
    on E: Exception do
    begin
      dolog(llFatal, 'BUG: Unhandled exception in epoll worker thread!');
      dolog(llFatal, DumpExceptionCallStack(e));
    end;
  end;
  Finalize;
  j:=FSocketCount;
  while j>=0 do
  begin
    RemoveSocket(FSockets[j]);
    Dec(j);
  end;
  FreeMem(data);
end;

procedure TEpollWorkerThread.RemoveSocket(Sock: TEPollSocket;
  doClose: Boolean; doFree: Boolean);
var
  i: Integer;
begin
  for i:=0 to FSocketCount-1 do
  if FSockets[i] = Sock then
  begin
    if epoll_ctl(epollfd, EPOLL_CTL_DEL, FSockets[i].Socket, nil)<0 then
      dolog(llError, ['epoll_ctl_del failed #', IntToStr(fpgeterrno)]);

    sock.FParent:=nil;

    Dec(FSocketCount);
    FSockets[i]:=FSockets[FSocketCount];

    if doFree then
    begin
      Sock.Dispose;
    end;
    Exit;
  end;
end;

procedure TEpollWorkerThread.ThreadTick;
var j: Integer;
begin
  inc(Fticks);
  if(FTicks>=ClientTickInterval) then
  begin
    FTicks:=0;
    j:=FSocketCount-1;
    while j>=0 do
    begin
      { observed: exception here when terminating - probably a race condition
        that appears when socket-classes are free'd elsewhere but not removed
        from FSockets array -  not a serious issue but should be investigated
        nevertheless! }
      if (FSockets[j].CheckTimeout)or Terminated then
      begin
        RemoveSocket(FSockets[j]);
        Dec(j, 2);
      end else
        Dec(j);
    end;
  end;
end;

procedure TEpollWorkerThread.Initialize;
begin

end;

procedure TEpollWorkerThread.Finalize;
begin

end;

constructor TEpollWorkerThread.Create(aParent: TObject);
begin
  FParent:=aParent;

  if assignpipe(FPipeOutput, FPipeInput)<>0 then
    dolog(llError, 'Could not create pipes for epoll worker thread!');

  inherited Create(False);
end;

destructor TEpollWorkerThread.Destroy;
var
  i: Integer;
begin
  for i:=0 to FSocketCount-1 do
    FSockets[i].Free;

  FSocketCount:=0;
  inherited Destroy;
end;

function TEpollWorkerThread.Callback(Method: TEPollCallbackProc): Boolean;
begin
  result:=FpWrite(FPipeInput, Method, sizeof(Method)) = Sizeof(Method);
end;

function TEpollWorkerThread.AddSocket(Sock: TEPollSocket): Boolean;
var
  event: epoll_event;
begin
  if FSocketCount>=MaxConnectionsPerThread then
  begin
    dolog(llDebug, 'worker thread is at maximum capacity, dropping connection!');
    result:=False;
    Exit;
  end;

  Inc(FTotalCount);
  FSockets[FSocketCount]:=Sock;

  if Sock.WantSSL then
  begin
    Sock.StartSSL;
    Sock.WantSSL:=False;

    if not Sock.IsSSL then
    begin
      result:=False;
      Exit;
    end;
  end;

  event.Events:=EPOLLIN;
  event.Data.ptr:=Sock;

  if epoll_ctl(epollfd, EPOLL_CTL_ADD, Sock.Socket, @event)<0 then
  begin
    dolog(llDebug, ['epoll_ctl_add failed, error #', IntToStr(fpgeterrno), ' ', IntToStr(Sock.FSocket)]);
    result:=False;
  end else
  begin
    Inc(FSocketCount);
    result:=True;

    if Assigned(FOnConnection) then
      FOnConnection(Sock);
  end;
end;

end.

