package com.mydlp.backend.thrift;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.Reader;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.Charset;

import org.apache.thrift.TException;
import org.apache.tika.Tika;
import org.apache.tika.io.IOUtils;
import org.apache.tika.metadata.Metadata;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.mydlp.seclore.FileSecureConfigBuilder;
import com.mydlp.seclore.FileSecureException;
import com.mydlp.seclore.FileSecureProtect;
import com.mydlp.seclore.MyDLPCertificateException;

public class MydlpImpl implements Mydlp.Iface {
	
	private static Logger logger = LoggerFactory.getLogger(MydlpImpl.class);

	protected static final String DEFAULT_ENCODING = "UTF-8";
	protected static final ByteBuffer EMPTY = Charset.forName(DEFAULT_ENCODING)
			.encode(CharBuffer.wrap(""));
	protected static final ByteBuffer ERROR = Charset.forName(DEFAULT_ENCODING)
			.encode(CharBuffer.wrap("mydlp-internal/error"));
	protected static final String MIME_NOT_FOUND = "mydlp-internal/not-found";
	
	protected Tika tika = new Tika();
	
	protected FileSecureConfigBuilder secloreConfig = null;
	
	protected FileSecureProtect secloreProtect = null;
		
	protected InputStream getInputStream(final ByteBuffer buf) {
		return new InputStream() {
			public synchronized int read() throws IOException {
				return buf.hasRemaining() ? buf.get() : -1;
			}

			public synchronized int read(byte[] bytes, int off, int len)
					throws IOException {
				int rv = Math.min(len, buf.remaining());
				buf.get(bytes, off, rv);
				return rv == 0 ? -1 : rv;
			}
		};
	}

	@Override
	public String getMime(String FileName, ByteBuffer Data) throws TException {
		Metadata metadata = new Metadata();
		if (FileName != null && FileName.length() > 0)
			metadata.add(Metadata.RESOURCE_NAME_KEY, FileName);
		InputStream inputStream = getInputStream(Data);
		try {
			return tika.detect(inputStream, metadata);
		} catch (IOException e) {
			logger.error("Can not detect file type", e);
			return MIME_NOT_FOUND;
		} catch (Throwable e) {
			logger.error("Can not detect file type", e);
			return MIME_NOT_FOUND;
		} finally {
			try {
				inputStream.close();
			} catch (IOException e) {
				logger.error("Can not close stream", e);
			}
		}
	}
	
	protected Boolean isMemoryError(Throwable t) {
		if (t instanceof OutOfMemoryError)
			return true;
		
		Throwable cause = t.getCause();
		if (cause == null)
			return false;
		return isMemoryError(cause);
	}

	@Override
	public ByteBuffer getText(String FileName, String MimeType, ByteBuffer Data)
			throws TException {
		InputStream inputStream = getInputStream(Data);
		try {
			Metadata metadata = new Metadata();
			if (FileName != null && FileName.length() > 0)
				metadata.add(Metadata.RESOURCE_NAME_KEY, FileName);
			metadata.add(Metadata.CONTENT_TYPE, MimeType);
			Reader reader = tika.parse(inputStream, metadata);
			return ByteBuffer.wrap(IOUtils.toByteArray(reader, DEFAULT_ENCODING));
		} catch (Throwable e) {
			if (isMemoryError(e))
			{
				logger.error("Can not allocate required memory", e);
				return EMPTY;
			}
			else
			{
				logger.error("Can not read text", e);
				return ERROR;
			}
		} finally {
			try {
				inputStream.close();
			} catch (IOException e) {
				logger.error("Can not close stream", e);
			}
		}

	}

	@Override
	public String secloreInitialize(String SecloreAppPath,
			String SecloreAddress, int SeclorePort, String SecloreAppName,
			int SecloreHotFolderCabinetId,
			String SecloreHotFolderCabinetPassphrase,
			int SeclorePoolSize) throws TException {
		try {
			if (secloreProtect != null || secloreConfig != null)
				secloreTerminate();
			
			secloreConfig = new FileSecureConfigBuilder(SecloreAppPath, SecloreAddress, SeclorePort, 
							SecloreAppName, SecloreHotFolderCabinetId, SecloreHotFolderCabinetPassphrase, SeclorePoolSize);
			try {
				secloreConfig.installCertificateIfNotExists();
			} catch (MyDLPCertificateException e) {
				logger.error("An error occurred when install seclore remote certificate", e);
			}
			
			secloreProtect = new FileSecureProtect(secloreConfig);
			
			try {
				secloreProtect.initialize();
				return "ok";
			} catch (FileSecureException e) {
				logger.error("An error occurred when initializing seclore configuration", e);
				return e.getMessage();
			}
		} catch (Throwable e) {
			logger.error("An error unexpected occurred when initializing seclore configuration", e);
			return "mydlp.backend.seclore.initialize.unexpectedException";	
		}
	}

	@Override
	public String secloreProtect(String FilePath, int HotFolderId,
			String ActivityComments) throws TException {
		if (secloreProtect == null) {
			return "mydlp.backend.seclore.protect.notInitialized";
		}
		try {
			File file = new File(FilePath);
			if (!file.exists())
				return "mydlp.backend.seclore.protect.fileNotFound";
			if (!file.isFile())
				return "mydlp.backend.seclore.protect.notRegularFile";
			if (!file.canRead())
				return "mydlp.backend.seclore.protect.canNotRead";
			if (!file.canWrite())
				return "mydlp.backend.seclore.protect.canNotWrite";
			String fileId = secloreProtect.protect(file.getAbsolutePath(), HotFolderId, ActivityComments);
			return "ok " + fileId; 
		} catch (FileSecureException e) {
			logger.error("An error occurred when protecting document ( " +
					FilePath + " ) woth hot folder id (" + HotFolderId + " )", e);
			return e.getMessage();
		} catch (Throwable e) {
			logger.error("An error unexpected occurred when protecting document ( " +
					FilePath + " ) woth hot folder id (" + HotFolderId + " )", e);
			return "mydlp.backend.seclore.protect.unexpectedException";	
		}
	}

	@Override
	public String secloreTerminate() throws TException {
		if (secloreProtect == null) {
			return "mydlp.backend.seclore.terminate.notInitialized";
		}
		try {
			secloreProtect.terminate();
			secloreConfig = null;
			secloreProtect = null;
			return "ok"; 
		} catch (FileSecureException e) {
			logger.error("An error occurred when terminating seclore connection", e);
			return e.getMessage();
		} catch (Throwable e) {
			logger.error("An error unexpected occurred when terminating seclore connection", e);
			return "mydlp.backend.seclore.protect.unexpectedException";	
		}
	}

	@Override
	public ByteBuffer getUnicodeText(String Encoding, ByteBuffer Data)
			throws TException {
		// TODO Auto-generated method stub
		return null;
	}

}
