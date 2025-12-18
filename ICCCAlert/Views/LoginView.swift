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
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.05, green: 0.4, blue: 0.95),
                        Color(red: 0.1, green: 0.5, blue: 1.0)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // Floating circles background decoration
                GeometryReader { geometry in
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 200, height: 200)
                        .offset(x: -50, y: 100)
                    
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 150, height: 150)
                        .offset(x: geometry.size.width - 80, y: geometry.size.height - 200)
                }
                
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer()
                            .frame(height: 60)
                        
                        // Logo/Header Section
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(width: 100, height: 100)
                                
                                Image(systemName: "bell.badge.fill")
                                    .font(.system(size: 50))
                                    .foregroundColor(.white)
                            }
                            
                            Text("ICCC Alert")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.white)
                            
                            Text("Stay connected with real-time alerts")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .padding(.bottom, 50)
                        
                        // Login Card
                        VStack(spacing: 24) {
                            // Title
                            VStack(spacing: 8) {
                                Text(isOTPSent ? "Verify OTP" : "Welcome Back")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(.primary)
                                
                                Text(isOTPSent ? "Enter the code sent to +91 \(phone)" : "Sign in to continue")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                            .padding(.top, 8)
                            
                            // Input Fields
                            VStack(spacing: 16) {
                                // Phone Number Field
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Phone Number")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                    
                                    HStack(spacing: 12) {
                                        Image(systemName: "phone.fill")
                                            .foregroundColor(.blue)
                                            .frame(width: 20)
                                        
                                        Text("+91")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        
                                        Divider()
                                            .frame(height: 24)
                                        
                                        TextField("10-digit mobile number", text: $phone)
                                            .keyboardType(.numberPad)
                                            .textContentType(.telephoneNumber)
                                            .disabled(isOTPSent)
                                    }
                                    .padding()
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(.systemGray6))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(isOTPSent ? Color.gray.opacity(0.3) : Color.blue.opacity(0.5), lineWidth: 1)
                                    )
                                }
                                .opacity(isOTPSent ? 0.6 : 1.0)
                                
                                // OTP Field
                                if isOTPSent {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("One-Time Password")
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundColor(.secondary)
                                        
                                        HStack(spacing: 12) {
                                            Image(systemName: "lock.shield.fill")
                                                .foregroundColor(.blue)
                                                .frame(width: 20)
                                            
                                            TextField("Enter OTP", text: $otp)
                                                .keyboardType(.numberPad)
                                                .textContentType(.oneTimeCode)
                                        }
                                        .padding()
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color(.systemGray6))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                                        )
                                    }
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
                            
                            // Action Button
                            Button(action: handleAction) {
                                HStack {
                                    if isLoading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Text(isOTPSent ? "Verify & Sign In" : "Send OTP")
                                            .fontWeight(.semibold)
                                        
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: isButtonDisabled ? 
                                            [Color.gray, Color.gray] :
                                            [Color(red: 0.05, green: 0.4, blue: 0.95), Color(red: 0.1, green: 0.5, blue: 1.0)]
                                        ),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .shadow(color: isButtonDisabled ? .clear : Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                            }
                            .disabled(isButtonDisabled)
                            .padding(.top, 8)
                            
                            // Change Number Button
                            if isOTPSent {
                                Button(action: resetLogin) {
                                    HStack {
                                        Image(systemName: "arrow.left")
                                            .font(.caption)
                                        Text("Change Number")
                                            .fontWeight(.medium)
                                    }
                                    .foregroundColor(.blue)
                                }
                                .transition(.opacity)
                            }
                        }
                        .padding(32)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color(.systemBackground))
                                .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
                        )
                        .padding(.horizontal, 24)
                        
                        Spacer()
                            .frame(height: 40)
                        
                        // Register Button
                        Button(action: {
                            showRegistration = true
                        }) {
                            HStack(spacing: 4) {
                                Text("Don't have an account?")
                                    .foregroundColor(.white.opacity(0.9))
                                Text("Register")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 24)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.2))
                            )
                        }
                        
                        Spacer()
                            .frame(height: 40)
                    }
                }
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
                withAnimation(.spring()) {
                    isOTPSent = true
                }
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
                
                DispatchQueue.main.async {
                    // The app will automatically transition to ContentView
                }
            } else {
                print("❌ Login failed: \(message)")
                errorMessage = message
                showError = true
                otp = ""
            }
        }
    }
    
    private func resetLogin() {
        withAnimation(.spring()) {
            isOTPSent = false
            otp = ""
        }
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AuthManager.shared)
    }
}