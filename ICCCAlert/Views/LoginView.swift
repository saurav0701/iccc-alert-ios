import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var phone = ""
    @State private var otp = ""
    @State private var isOTPSent = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showRegistration = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Spacer()
                
                // Logo/Header
                VStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("ICCC Alert")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Stay connected with real-time alerts")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 40)
                
                // Login Form
                VStack(spacing: 16) {
                    // Phone Number
                    HStack {
                        Text("+91")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        TextField("Phone Number", text: $phone)
                            .keyboardType(.numberPad)
                            .textContentType(.telephoneNumber)
                            .disabled(isOTPSent)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    
                    // OTP Field (if OTP sent)
                    if isOTPSent {
                        TextField("Enter OTP", text: $otp)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                    }
                    
                    // Action Button
                    Button(action: handleAction) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text(isOTPSent ? "Verify OTP" : "Send OTP")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isButtonDisabled ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(isButtonDisabled)
                    
                    // Change Number (if OTP sent)
                    if isOTPSent {
                        Button("Change Number") {
                            resetLogin()
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 30)
                
                Spacer()
                
                // Register Button
                Button(action: {
                    showRegistration = true
                }) {
                    HStack {
                        Text("Don't have an account?")
                            .foregroundColor(.secondary)
                        Text("Register")
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationBarHidden(true)
            .alert(isPresented: $showError) {
                Alert(
                    title: Text("Error"),
                    message: Text(errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showRegistration) {
                RegistrationView()
            }
        }
    }
    
    private var isButtonDisabled: Bool {
        if isLoading {
            return true
        }
        if isOTPSent {
            return otp.count < 4
        } else {
            return phone.count != 10
        }
    }
    
    private func handleAction() {
        if isOTPSent {
            verifyOTP()
        } else {
            requestOTP()
        }
    }
    
    private func requestOTP() {
        guard phone.count == 10 else {
            errorMessage = "Please enter a valid 10-digit phone number"
            showError = true
            return
        }
        
        isLoading = true
        
        authManager.requestOTP(phone: phone) { success, message in
            isLoading = false
            
            if success {
                isOTPSent = true
                print("✅ OTP sent successfully")
            } else {
                errorMessage = message
                showError = true
                print("❌ OTP request failed: \(message)")
            }
        }
    }
    
    private func verifyOTP() {
        guard otp.count >= 4 else {
            errorMessage = "Please enter a valid OTP"
            showError = true
            return
        }
        
        isLoading = true
        
        print("🔐 Verifying OTP for phone: \(phone)")
        
        authManager.verifyOTP(phone: phone, otp: otp) { success, message in
            isLoading = false
            
            if success {
                print("✅ Login successful")
                print("✅ User authenticated: \(authManager.isAuthenticated)")
                print("✅ Current user: \(authManager.currentUser?.name ?? "nil")")
                
                // ✅ CRITICAL: Force UI update
                DispatchQueue.main.async {
                    // The app will automatically transition to ContentView
                    // because authManager.isAuthenticated is now true
                }
            } else {
                print("❌ Login failed: \(message)")
                errorMessage = message
                showError = true
                otp = "" // Clear OTP on failure
            }
        }
    }
    
    private func resetLogin() {
        isOTPSent = false
        otp = ""
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AuthManager.shared)
    }
}