//
//  SSLService.swift
//  SSLService
//
//  Created by Bill Abt on 5/26/16.
//
//  Copyright © 2016 IBM. All rights reserved.
//
// 	Licensed under the Apache License, Version 2.0 (the "License");
// 	you may not use this file except in compliance with the License.
// 	You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// 	Unless required by applicable law or agreed to in writing, software
// 	distributed under the License is distributed on an "AS IS" BASIS,
// 	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// 	See the License for the specific language governing permissions and
// 	limitations under the License.
//

import Foundation
import Socket
import OpenSSL

// MARK: SSLService

///
/// SSL Service Plugin for Socket using OpenSSL
///
public class SSLService : SSLServiceDelegate {
	
	// MARK: Constants
	
	let DEFAULT_VERIFY_DEPTH: Int32				= 4
	
	// MARK: Configuration
	
	///
	/// SSL Configuration
	///
	public struct Configuration {
		
		// MARK: Properties
		
		/// Path to the certificate file to be used.
		public private(set) var certificateFilePath: String
		
		/// Path to the key file to be used.
		public private(set) var keyFilePath: String
		
		/// Path to the certificate chain file (optional).
		public private(set) var certificateChainFilePath: String?
		
		// MARK: Lifecycle
		
		///
		/// Initialize a configuration
		///
		/// - Parameters:
		///		- certificateFilePath:		Path to the PEM formatted certificate file.
		///		- keyFilePath:				Path to the PEM formatted key file (optional). If nil, `certificateFilePath` is used.
		///		- chainFilePath:			Path to the certificate chain file (optional).
		///
		///	- Returns:	New Configuration instance.
		///
		public init?(certificateFilePath: String, keyFilePath: String? = nil, chainFilePath: String? = nil) throws {
			
			self.certificateFilePath = certificateFilePath
			self.keyFilePath = keyFilePath ?? certificateFilePath
			self.certificateChainFilePath = chainFilePath
		}
	}
	
	// MARK: Properties
	
	// MARK: -- Public
	
	/// SSL Configuration (Read only)
	public private(set) var configuration: Configuration
	
	// MARK: -- Private
	
	/// True if setup as server, false if setup as client.
	private var isServer: Bool = true
	
	/// SSL Connection
	private var cSSL: UnsafeMutablePointer<SSL>? = nil
	
	/// SSL Method
 	/// **Note:** We use `SSLv23` which causes negotiation of the highest available SSL/TLS version.
	private var method: UnsafePointer<SSL_METHOD>? = nil
	
	/// SSL Context
	private var context: UnsafeMutablePointer<SSL_CTX>? = nil
	
	
	// MARK: Lifecycle
	
	///
	/// Initialize an SSLService instance.
	///
	/// - Parameter config:		Configuration to use.
	///
	/// - Returns: SSLServer instance.
	///
	public init?(usingConfiguration config: Configuration) throws {
		
		// Store it...
		self.configuration = config
	
		// Validate the config...
		try self.validate(configuration: config)
	}
	
	
	// MARK: SSLServiceDelegate Protocol
	
	///
	/// Initialize SSL Service
	///
	/// - Parameter isServer:	True for initializing a server, otherwise a client.
	///
	public func initialize(isServer: Bool) throws {
		
		// Common initialization...
		SSL_load_error_strings()
		SSL_library_init()
		OPENSSL_add_all_algorithms_noconf()
		
		// Server or client specific method determination...
		self.isServer = isServer
		if isServer {
			
			self.method = SSLv23_server_method()
			
		} else {
			
			self.method = SSLv23_client_method()
		}
		
		// Prepare the context...
		try self.prepareContext()
	}
	
	///
	/// Deinitialize SSL Service
	///
	public func deinitialize() {
		
		// Shutdown and then free SSL pointer...
		if self.cSSL != nil {
			SSL_shutdown(self.cSSL!)
			SSL_free(self.cSSL!)
		}

		// Now the context...
		if self.context != nil {
			SSL_CTX_free(self.context!)
		}
		
		// Finally, finish cleanup...
		ERR_free_strings()
		EVP_cleanup()
	}
	
	///
	/// Processing on acceptance from a listening socket
	///
	/// - Parameter socket:	The connected Socket instance.
	///
	public func onAccept(socket: Socket) throws {
		
		// Prepare the connection...
		let sslConnect = try prepareConnection(socket: socket)

		// Start the handshake...
		let rc = SSL_accept(sslConnect)
		if rc <= 0 {
			
			let sslError = SSL_get_error(sslConnect, rc)
			let reason = "ERROR: SSL_accept, code: \(sslError), reason: \(ERR_error_string(UInt(sslError), nil))"
			throw SSLError.fail(Int(sslError), reason)
		}
	}
	
	///
	/// Processing on connection to a listening socket
	///
	/// - Parameter socket:	The connected Socket instance.
	///
	public func onConnect(socket: Socket) throws {
		
		// Prepare the connection...
		let sslConnect = try prepareConnection(socket: socket)
		
		// Start the handshake...
		let rc = SSL_connect(sslConnect)
		if rc <= 0 {
			
			let sslError = SSL_get_error(sslConnect, rc)
			let reason = "ERROR: SSL_connect, code: \(sslError), reason: \(ERR_error_string(UInt(sslError), nil))"
			throw SSLError.fail(Int(sslError), reason)
		}
	}
	
	///
	/// Do connection verification
	///
	public func verifyConnection() throws {
		
		
	}
	
	///
	/// Low level writer
	///
	/// - Parameters:
	///		- buffer:		Buffer pointer.
	///		- bufSize:		Size of the buffer.
	///
	///	- Returns the number of bytes written. Zero indicates SSL shutdown, less than zero indicates error.
	///
	public func send(buffer: UnsafePointer<Void>!, bufSize: Int) throws -> Int {
		
		let rc = SSL_write(self.cSSL!, buffer, Int32(bufSize))
		if rc < 0 {
			
			let sslError = SSL_get_error(self.cSSL!, rc)
			let reason = "ERROR: SSL_write, code: \(sslError), reason: \(ERR_error_string(UInt(sslError), nil))"
			throw SSLError.fail(Int(sslError), reason)
		}
		return Int(rc)
	}
	
	///
	/// Low level reader
	///
	/// - Parameters:
	///		- buffer:		Buffer pointer.
	///		- bufSize:		Size of the buffer.
	///
	///	- Returns the number of bytes read. Zero indicates SSL shutdown, less than zero indicates error.
	///
	public func recv(buffer: UnsafeMutablePointer<Void>!, bufSize: Int) throws -> Int {
		
		let rc = SSL_read(self.cSSL!, buffer, Int32(bufSize))
		if rc < 0 {
			
			let sslError = SSL_get_error(self.cSSL!, rc)
			let reason = "ERROR: SSL_read, code: \(sslError), reason: \(ERR_error_string(UInt(sslError), nil))"
			throw SSLError.fail(Int(sslError), reason)
		}
		return Int(rc)
	}
	
	// MARK: Private Methods
	
	///
	/// Validate configuration
	///
	/// - Parameter configuration:	Configuration to validate.
	///
	private func validate(configuration: Configuration) throws {
		
		#if os(Linux)
			// See if we've got everything...
			//	- First the certificate file...
			if !NSFileManager.defaultManager().fileExists(atPath: configuration.certificateFilePath) {
				
				throw SSLError.fail(Int(ENOENT), "Certificate doesn't exist at specified path.")
			}
			
			//	- Now the key file...
			if !NSFileManager.defaultManager().fileExists(atPath: configuration.keyFilePath) {
				
				throw SSLError.fail(Int(ENOENT), "Key file doesn't exist at specified path.")
			}
			
			//	- Finally, if present, the certificate chain path...
			if let chainPath = configuration.certificateChainFilePath {
				
				if !NSFileManager.defaultManager().fileExists(atPath: chainPath) {
					
					throw SSLError.fail(Int(ENOENT), "Certificate chain doesn't exist at specified path.")
				}
			}
		#else
			// See if we've got everything...
			//	- First the certificate file...
			if !NSFileManager.default().fileExists(atPath: configuration.certificateFilePath) {
				
				throw SSLError.fail(Int(ENOENT), "Certificate doesn't exist at specified path.")
			}
			
			//	- Now the key file...
			if !NSFileManager.default().fileExists(atPath: configuration.keyFilePath) {
				
				throw SSLError.fail(Int(ENOENT), "Key file doesn't exist at specified path.")
			}
			
			//	- Finally, if present, the certificate chain path...
			if let chainPath = configuration.certificateChainFilePath {
				
				if !NSFileManager.default().fileExists(atPath: chainPath) {
					
					throw SSLError.fail(Int(ENOENT), "Certificate chain doesn't exist at specified path.")
				}
			}
		#endif
	}
	
	///
	/// Prepare the context.
	///
	private func prepareContext() throws {
		
		// First create the context...
		self.context = SSL_CTX_new(self.method!)
		
		guard let context = self.context else {
			
			let reason = "ERROR: Unable to create SSL context."
			throw SSLError.fail(Int(ENOMEM), reason)
		}
		
		// Handle the client/server specific stuff first...
		if self.isServer {
			
			SSL_CTX_set_verify(context, SSL_VERIFY_NONE, nil)
		
		} else {
			
			SSL_CTX_set_verify(context, SSL_VERIFY_PEER, nil)
			SSL_CTX_set_verify_depth(context, DEFAULT_VERIFY_DEPTH)
			SSL_CTX_ctrl(context, SSL_CTRL_OPTIONS, SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3 | SSL_OP_NO_COMPRESSION, nil)
		}

		// Now configure the rest...
		//	- First the certificate...
		var rc = SSL_CTX_use_certificate_file(context, self.configuration.certificateFilePath, SSL_FILETYPE_PEM)
		if rc <= 0 {
			
			let err = ERR_get_error()
			let reason = "ERROR: Certificate file, code: \(err), reason: \(ERR_error_string(err, nil))"
			throw SSLError.fail(Int(err), reason)
		}
		
		///	- Private key file comes next...
		rc = SSL_CTX_use_PrivateKey_file(context, self.configuration.keyFilePath, SSL_FILETYPE_PEM)
		if rc <= 0 {
			
			let err = ERR_get_error()
			let reason = "ERROR: Key file, code: \(err), reason: \(ERR_error_string(err, nil))"
			throw SSLError.fail(Int(err), reason)
		}
		
		//	- Check validity of the private key...
		rc = SSL_CTX_check_private_key(context)
		if rc <= 0 {
			
			let err = ERR_get_error()
			let reason = "ERROR: Check private key, code: \(err), reason: \(ERR_error_string(err, nil))"
			throw SSLError.fail(Int(err), reason)
		}
		
		//	- Finally, if present, the certificate chain path...
		if let chainPath = configuration.certificateChainFilePath {
			
			rc = SSL_CTX_use_certificate_chain_file(context, chainPath)
			if rc <= 0 {
				
				let err = ERR_get_error()
				let reason = "ERROR: Certificate chain file, code: \(err), reason: \(ERR_error_string(err, nil))"
				throw SSLError.fail(Int(err), reason)
			}
		}
	}
	
	///
	/// Prepare the connection for either server or client use.
	///
	/// - Parameter socket:	The connected Socket instance.
	///
	/// - Returns: `UnsafeMutablePointer` to the SSL connection.
	///
	private func prepareConnection(socket: Socket) throws -> UnsafeMutablePointer<SSL> {
	
		// Make sure our context is valid...
		guard let context = self.context else {
			
			let reason = "ERROR: Unable to access SSL context."
			throw SSLError.fail(Int(EFAULT), reason)
		}
		
		// Now create the connection...
		self.cSSL = SSL_new(context)
		
		guard let sslConnect = self.cSSL else {
			
			let reason = "ERROR: Unable to create SSL connection."
			throw SSLError.fail(Int(EFAULT), reason)
		}
		
		// Set the socket file descriptor...
		SSL_set_fd(sslConnect, socket.socketfd)
		
		return sslConnect
	}
}
