import SwiftUI

struct LoginView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var phone = ""
    @State private var otp = ""
    @State private var otpSent = false
    @State private var errorMessage = ""
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 30) {
            // Logo/Title
            VStack(spacing: 10) {
                Image(systemName: "bell.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("ICCC Alert")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Integrated Command & Control Centre")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 50)
            
            Spacer()
            
            // Login Form
            VStack(spacing: 20) {
                if !otpSent {
                    // Phone Input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Phone Number")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("+91")
                                .foregroundColor(.secondary)
                            TextField("10-digit phone", text: $phone)
                                .keyboardType(.phonePad)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    
                    Button(action: sendOTP) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Send OTP")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(phone.count == 10 ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(phone.count != 10 || isLoading)
                    
                } else {
                    // OTP Input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter OTP")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        TextField("6-digit OTP", text: $otp)
                            .keyboardType(.numberPad)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                    }
                    
                    Button(action: verifyOTP) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Verify OTP")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(otp.count == 6 ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(otp.count != 6 || isLoading)
                    
                    Button(action: {
                        otpSent = false
                        otp = ""
                        errorMessage = ""
                    }) {
                        Text("Change Phone Number")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                }
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 30)
            
            Spacer()
        }
    }
    
    func sendOTP() {
        isLoading = true
        errorMessage = ""
        
        authManager.requestOTP(phone: phone) { success, message in
            isLoading = false
            if success {
                otpSent = true
            } else {
                errorMessage = message
            }
        }
    }
    
    func verifyOTP() {
        isLoading = true
        errorMessage = ""
        
        authManager.verifyOTP(phone: phone, otp: otp) { success, message in
            isLoading = false
            if !success {
                errorMessage = message
            }
        }
    }
}